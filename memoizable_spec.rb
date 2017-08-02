require 'rails_helper'

RSpec.describe Memoizable do
  before :each do
    @car1 = FactoryGirl.create(:car)
    @car2 = FactoryGirl.create(:car)
    @car3 = FactoryGirl.create(:car)
    @car4 = FactoryGirl.create(:car)

    # should have 1 room included in loan AND open
    # 3 open rooms
    # 1 partial room
    @room1 = FactoryGirl.create(:room, partial_bunk_room: false)
    @room2 = FactoryGirl.create(:room, oakland_room: FactoryGirl.create(:credit_report_credit_room, open: true), partial_bunk_room: true)
    @room3 = FactoryGirl.create(:room, oakland_room: FactoryGirl.create(:credit_report_credit_room, open: true), partial_bunk_room: false)
    @room4 = FactoryGirl.create(:room, oakland_room: FactoryGirl.create(:credit_report_credit_room, open: true), partial_bunk_room: false)

    @setting = FactoryGirl.create(:setting)
    @renter = FactoryGirl.create(:renter, user: FactoryGirl.create(:user, fridge_percentage: @setting.dsc_fee_discount_percent))

    @user = @renter.user
    @user.update_column( :state, :approved ) # user needs to be approved or later to associate cars

    @user.cars << @car1
    @user.cars << @car2
    @user.cars << @car3
    @user.cars << @car4

    @user.rooms << @room1
    @user.rooms << @room2
    @user.rooms << @room3
    @user.rooms << @room4

    @car1.rent
    @car2.rent

    @user.update_column(:state, :rented_and_live)
    @user.memoize_synchronously
    @user.locked = true
  end

  describe 'locking_and_memoization' do
    it 'should be able to show the memoized renter as a MemoizedHash' do
      expect(@user.renter).to be_a(Memoizable::MemoizedHash)
    end

    it 'should be able to get all rooms and cars' do
      expect(@user.rooms.size).to eq(4)
      expect(@user.cars.size).to eq(4)
    end

    it 'it should be able to chain scopes' do
      expect(@user.cars.rented.size).to eq(2)
      expect(@user.cars.pending.size).to eq(2)
      expect(@user.rooms.open_rooms.size).to eq(3)
      expect(@user.rooms.partial_rooms.size).to eq(1)

      expect(@user.rooms.partial_rooms.open_rooms.size).to eq(1)
    end

    it 'should sum values of a certain column across a has_many association' do
      expect(@user.cars.sum(:payment)).to eq(1600)
    end

    it 'should be able to order by an element in a has_many association' do
      min = @user.cars.min_by(&:id).id
      max = @user.cars.max_by(&:id).id
      expect(@user.cars.order(id: :desc).first.id).to eq(max)
      expect(@user.cars.order(id: :asc).first.id).to eq(min)
    end

    it 'should format dates as Dates' do
      expect(@user.cars.first.renting_date).to be_a(Date)
    end

    it 'should format dates with times as DateTimes' do
      expect(@user.cars.first.created_at).to be_a(DateTime)
    end

    it 'should have the klass for the object it is ultimately representing' do
      expect(@user.cars.first.klass.name).to eq('car')
    end

    it 'should return a MemoizedHash for has_one relations' do
      expect(@user.renter.klass.name).to eq('renter')
    end

    it 'should just return nil for something an element that does not exist' do
      expect(@user.renter.foo_bala).to be_nil
    end

    it 'should just return an empty array for an association or scope that does not exist' do
      expect(@user.cars.rented.foo_bar).to eq([])
    end

    it 'should memoize at the memloized_and_locked at state' do
      @user.update_column(:state, :approved)
      @user.payment_frequency = 'Semi-monthly'
      @user.memoize_synchronously
      @user.update_column(:state, :rented_and_live)
      expect(@user.payment_frequency).to eq('Monthly')
    end

    it 'should return a memory at a state specified (when locked) and also stop when asked' do
      @user.locked = false
      @user.update_column(:state, :approved)
      @user.payment_frequency = 'Semi-monthly'
      @user.memoize_synchronously
      @user.update_column(:state, :rented_and_live)
      @user.payment_frequency = 'Monthly'
      @user.memoize_synchronously
      @user.locked = true
      expect(@user.payment_frequency).to eq('Monthly')
      @user.memory_at(:approved)
      expect(@user.payment_frequency).to eq('Semi-monthly')
      @user.stop_remembering
      expect(@user.payment_frequency).to eq('Monthly')
    end

    it 'should return a memory at a state specified (when NOT locked) and also stop when asked' do
      @user.locked = false
      @user.update_column(:state, :approved)
      @user.payment_frequency = 'Semi-monthly'
      @user.memoize_synchronously
      @user.update_column(:state, :rented_and_live)
      @user.payment_frequency = 'Monthly'
      @user.memory_at(:approved)
      expect(@user.payment_frequency).to eq('Semi-monthly')
      @user.stop_remembering
      expect(@user.payment_frequency).to eq('Monthly')
    end


    it 'should memoize attributes that are not specified explicitly' do
      expect(@user.methods).to include(:id_with_memoization, :id_without_memoization)
    end

    it 'should memoize anything requested' do
      expect(@user.methods).to include(:rooms_with_memoization,
                                           :partner_managed_with_memoization?)
    end

    it 'should have functional question mark accessors' do
      expect(@user.id?).to be_truthy
      expect(@user.partner_managed?).to be_falsey
    end
  end
end
