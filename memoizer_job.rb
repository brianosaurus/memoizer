# async memoization for huge things
class MemoizerJob
  include Sidekiq::Worker

  def perform(memoizer_id, memoizer_class)
    memoizer = memoizer_class.constantize.find_by_id(memoizer_id)
    if memoizer.present?
      begin
        memoizer.memoize_synchronously
      rescue StandardError => e
        logger.error("error memoizing #{memoizer_class} #{memoizer_id}")
      end
    else
      logger.error("WARNING: Could not find a #{memoizer_class} with id '#{memoizer_id}'")
    end
  end
end
