# A module that will save the state of your object as json
#
# Usage
#
# class Foo < ActiveRecord::Base
#   include Memoizable
#
#   # Now, simply tell memoize which scopes, associations, or instance methods to memoize
#   memoize :contract, :borrower
#
#   def some_computed_value
#     1 + 23
#   end
#   memoize :some_computed_value
# end
#
# That's all you have to do to make something memoizable.
#
# To save it simply call
# obj.memoize or obj.memoize_synchronously
#
# To view a memoized object lock it or view a previous state using
# obj.memory_at(state)
#
module Memoizable
  extend ActiveSupport::Concern

  # this array is meant to look like an active record array where scopes can be accessed
  class MemoizedArray < Array
    attr_accessor :parent, :name, :klass

    def initialize(array, parent, name, klass = nil)
      super(array)

      @parent = parent
      @name   = name.to_s
      @klass  = klass.present? ? klass.to_s.camelize.constantize : nil

      self.each_with_index do |val, index|
        case val
        when MemoizedHash, MemoizedArray
          val
        when Hash, ::Hash
          self[index] = MemoizedHash.new(val)
        when Array, ::Array
          self[index] = MemoizedArray.new(val, parent, index)
        else
          val
        end
      end
    end


    def respond_to_missing?(method_name, include_private = false)
      super
    end


    # this attempts to mimic scopes on active record by looking at the name and seeing
    # if there's a varaible
    def method_missing(method, *args)
      return super unless args.empty?

      val = parent.make_scoped_memoized_array(self.name, method)

      # if this is already a scope look for chained scopes like this:
      # borrower.included_accounts.funded_accounts
      if val.present?
        # simply gather ids from self and the returned array
        ids = self.map(&:id)
        val = val.reject { |item| !ids.include?(item.id) }
        val = MemoizedArray.new(val, parent, name, klass)
      end

      val ? val : super
    end


    # begins a series of hacks to mimic active record
    def sum(key)
      self.inject(0) { |sum, val| sum + val.send(key).to_i }
    end


    def order(sort)
      if sort.is_a? Hash
        key   = sort.to_a.first.first.to_s
        order = sort.to_a.first.last.to_s
      elsif sort.is_a? String
        key, order = sort.split.map(&:to_s)
      else
        # no idea how to deal, just return
        self
      end

      # anything that ends with _at turns into a date. Numbers are already handled correctly
      sorted = self.sort do |a, b|
        if order == 'desc'
          orderable(b, key) <=> orderable(a, key)
        else
          orderable(a, key) <=> orderable(b, key)
        end
      end

      # always return a MemoizedArray from anyting that mutates the collection
      MemoizedArray.new(sorted, parent, name, klass)
    end


    private def orderable(val, key)
      case key
      when key =~ /(_at)$/
        DateTime.parse(val[key])
      when key =~ /(_date)$/
        Date.parse(val[key])
      else
        val[key]
      end
    end
  end

  # We want things to look like active record objects and relations
  # see: https://github.com/intridea/hashie for info on Clash ahd Hashie
  class MemoizedHash < Hashie::Mash
    # this one needs to be directly overriden
    def zip
      self['zip'].present? ? self['zip'] : super
    end


    # stuff to make this look like an active record to active admin
    def klass
      self['__klass__'].present? ? self['__klass__'].constantize : nil
    end


    # a subtle hack to call real object's to_s if one was memoized
    def to_s
      self['to_s'].present? ? self['to_s'] : super
    end


    def respond_to?(method, *)
      method.to_sym == :klass ? self['__klass__'].present? : super
    end


    def attribute?(attr)
      self.key? attr.to_s
    end


    def column_for_attribute(attr)
      klass.nil? ? nil : self.klass.column_for_attribute(attr)
    end


    def make_scoped_memoized_array(name, method)
      val = self["#{name}_#{method}"]
      val ||= []
      MemoizedArray.new(val, self, name, self["#{name}__klass__"])
    end


    def respond_to_missing?(method_name, include_private = false)
      super
    end


    # finds things
    def method_missing(name, *args)
      return super unless args.empty?

      val = super(name.to_s)

      if val.nil?
        # using the #{attr}? accessor, find value and check state
        if name.to_s =~ /\?$/
          attr = name[0...-1]
          if self.klass&.attribute_names&.include? attr
            attr_val = super(attr)
            val = attr_val.nil? || attr_val.blank? ? false : true
          end
        elsif self.klass.present? && # if there's an unmemoized has_many relation just set an empty array
              (assoc = self.klass.reflect_on_association(name.to_sym)) &&
              assoc.class == ActiveRecord::Reflection::HasManyReflection
          val = []
        end
      end

      # convert the val to another MemoizedHash if it's a hash or
      # convert the vlaue to a memoized array if it's an array
      case val
      when MemoizedHash, MemoizedArray
        val
      when Hash, ::Hash
        MemoizedHash.new(val)
      when Array, ::Array
        MemoizedArray.new(val, self, name, self["#{name}__klass__"])
      when nil
        nil
      else
        if name =~ /(_at)$/
          DateTime.parse(val)
        elsif name =~ /(_date)$/
          Date.parse(val)
        else
          val
        end
      end
    end
  end


  included do
    singleton_class.class_eval { attr_accessor :memoized_methods, :memoized_scopes }

    attr_accessor :remembering_state
    has_many :memories, as: :memoizable


    # figures out what state from which to grab memoized json
    def memoized_json
      json = instance_variable_get(:'@__memoized_json')

      if json.nil?
        val = if self.remembering_state.present?
                self.memories.where("state = '#{self.remembering_state}'").order(created_at: :desc).first&.values
              else
                self.memories.order(created_at: :desc).first&.values
              end

        json = instance_variable_set(:'@__memoized_json', (val ? MemoizedHash.new(val) : nil))
      end

      json
    end


    # active record's attributes are saved automatically in as_json. It's why we call super in as_json.
    # however, if the record was memoized, we need to call the #{attribute}_with_memoization method
    # instead.
    #
    # It also turns out active record won't show us the attributes a class can have until after the first
    # find from the DB. So we have to make our method aliases in after_fine
    #
    # lastly, locked is a special column who's value we always to see ... not memoize so filter it out.
    after_initialize do |_obj|
      self.attribute_names.reject { |attr| ['locked'].include? attr }.each do |method|
        self.class.make_memoize_method method

        # now make a question mark accessor for the attribute if one doesn't exist
        next if self.respond_to? "#{method}_with_memoization?"
        singleton_class.class_eval do
          define_method("#{method}_with_memoization?") do
            val = self.send(method)
            val == true || val.present?
          end

          alias_method_chain "#{method}?", :memoization
        end
      end
    end


    # defines the method that's called in the place of the original method
    # then makes an alias for it.
    define_singleton_method(:make_memoize_method) do |method|
      method = method.to_s
      end_punctuation = ''
      short_method = method

      if method =~ /(\?|!)$/
        end_punctuation = Regexp.last_match(1)
        short_method = method.gsub(end_punctuation, '')
      end

      # make sure we haven't done this already since it'll cause loops
      return if self.method_defined? "#{short_method}_with_memoization#{end_punctuation}"

      # makes sure memoized state is available for whoever might want to use it
      define_method("#{short_method}_with_memoization#{end_punctuation}") do
        # if it's locked grab its memoized state
        if self.try(:locked?) || self.remembering_state
          cached_values = instance_variable_get(:'@__cached_memoized_values')
          cached_values ||= {}

          val = nil

          if cached_values[method.to_s].nil?
            # returns whatever it's set to
            val = memoized_json.send(method.to_s)
            cached_values[method.to_s] = val
            instance_variable_set(:'@__cached_memoized_values', cached_values)
          else
            val = cached_values[method.to_s]
          end

          val
        else
          self.send("#{short_method}_without_memoization#{end_punctuation}")
        end
      end

      alias_method_chain method, :memoization
    end


    # call this on each method who's val you want saved (you can use it on relations as well)
    #
    # Usage:
    # def foo
    #   self.bar + self.baz
    # end
    # memoizable :foo
    define_singleton_method(:memoizable) do |*methods|
      self.memoized_methods ||= []
      self.memoized_scopes ||= []

      # XXX: Sanity
      methods = methods.first if methods.first.is_a? Array

      methods.each do |method|
        method = method.to_s

        # ensure uniqueness so we don't have strange bugs
        next if self.memoized_methods.include?(method)

        if self.attribute_names.include?(method)
          self.memoized_methods.delete(method)
          next
        end

        # scopes are treated differently...we have to dig into the hash to find what
        # it *would* be
        if self.singleton_methods.include? method.to_sym
          self.memoized_scopes << method
        else
          self.memoized_methods << method
          self.make_memoize_method(method)
        end
      end
    end
  end


  # if any data is not present in the initial call to as_json then this method will add
  # it by scanning the methods that have been memoized and looking for whar's missing.
  def as_json(options = {})
    json = {}

    self.attribute_names.each { |method| json[method.to_s] = self.send(method) }

    # a trick to keep the class accessible to active admin
    json['__klass__'] = self.class.name

    return json unless options[:memoizing] == 'yes'

    # a trick to make all of this work nicely
    json.extend Hashie::Extensions::DeepMerge

    # we need to override this so that merges don't wipe out scoped data
    def json.merge!(hash)
      # the point here is not to overwrite arrays while memoizing since deep_merge will overwrite
      # memoized data
      val = self[hash.keys.first.to_s]
      return if val.is_a? Array

      self.deep_merge!(hash)
    end

    self.class.memoized_methods.each do |method|
      if (assoc = self.class.reflect_on_association(method.to_sym))
        relation = self.send(method)
        json[method.to_s] = relation.as_json(include_all: 'yes', memoizing: 'yes')

        # embed a class name with it so we can get at it later
        json["#{method}__klass__"] = (relation.respond_to?(:klass) ? relation.klass : relation.class).name

        # determine of there are scopes for the association and make
        # keys for each scope with values
        if assoc.class == ActiveRecord::Reflection::HasManyReflection
          klass = if assoc.options[:class_name].present?
                    assoc.options[:class_name].to_s.camelize.constantize
                  else
                    method.to_s.singularize.camelize.constantize
                  end

          # get the class and grab its memoized_scopes. Then pull them and add as keys
          klass.try(:memoized_scopes)&.each do |scope|
            skope = self.send(method).send(scope)
            json["#{method}_#{scope}"] = skope.as_json(include_all: 'yes', memoizing: 'yes')
            json["#{method}_#{scope}__klass__"] = (skope.respond_to?(:klass) ? skope.klass : skope.class).name
          end
        end
      else
        json[method.to_s] = self.send(method)
      end
    end

    json
  end


  private def current_user_id_or_nil
    User.current&.id
  end


  # lock and unlock a memoized object
  def locked=(val)
    return if self.locked == val
    update_column(:locked, val)
  end


  # can't save readonly records ... this prevents active record's save and update
  private def readonly?
    self.locked?
  end


  def memoize
    if Rails.env.test?
      memoize_synchronously
    else
      MemoizerJob.perform_in(30.seconds, self.id)
    end
  end


  # this will save the state of the including object's memoized methods
  def memoize_synchronously
    clear_cached_memoized_values

    json = self.as_json(memoizing: 'yes', include_all: 'yes')

    memory = Memory.new(
      state: self.try(:state),
      values: json,
      created_by_id: current_user_id_or_nil
    )
    self.memories << memory

    json
  end


  # only sets the memory at if it is possible
  def memory_at(state)
    if self.memories.where(state: state).limit(1).present?
      clear_cached_memoized_values
      self.remembering_state = state
      true
    else
      false
    end
  end


  def stop_remembering
    clear_cached_memoized_values
    self.remembering_state = nil
  end


  private def clear_cached_memoized_values
    @__cached_memoized_values = nil
    @__memoized_json = nil
  end
end


# super ugly hack that makes memoized hashes play nice with routes
module ActionDispatch
  module Routing
    class RouteSet
      # this is to get active admin to be nice
      class NamedRouteCollection
        private

        def define_url_helper(mod, route, name, opts, route_key, url_strategy)
          helper = UrlHelper.create(route, opts, route_key, url_strategy)
          mod.module_eval do
            define_method(name) do |*args|
              options = nil

              if args.any? { |arg| arg.is_a? Memoizable::MemoizedHash }
                args = args.map { |arg| arg.is_a?(Memoizable::MemoizedHash) ? arg.id : arg }
              end

              options = args.pop if args.last.is_a? Hash

              helper.call self, args, options
            end
          end
        end
      end
    end
  end
end


# antoher super ugly hack to get status tags to paint correctly
module ActiveAdmin
  module ViewHelpers
    # overriding this to get booleans to paint as yes/no
    module DisplayHelper
      def boolean_attr?(resource, attr)
        if resource.class.respond_to? :columns_hash
          resource.class.columns_hash[attr.to_s]&.type == :boolean

        # WOODS: the part we added
        elsif resource.try(:klass).respond_to? :columns_hash
          resource.klass.columns_hash[attr.to_s]&.type == :boolean
        end
      end
    end
  end
end
