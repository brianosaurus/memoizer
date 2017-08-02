# Memoizer

An ActiveRecord::Concern that will save your object (both computed and non-computed values) to a json blob. You can lock and recall previous states of the object just as it existed at the time you memoized it.

## How to use the memoizer

```rb
class Foo < ActiveRecord::Base
  include Memoizable

  # Now, simply tell memoize which scopes, associations, or instance methods to memoize
  memoize :contract, :borrower

  def some_computed_value
    1 + 23
  end
  memoize :some_computed_value
end

# That's it!

# To save it call
obj.memoize # this will use sidekiq

obj.memoize_synchronously # this will memoize in situ

# To view a memoized object lock it (for last known state) or view a previous state using
obj.memory_at(state)
```


## Postgres integration

This concern comes with an active record migration that will create the memories table. The table uses the postgres jsonb datatype. Some documentation on that data type can be found here: [jsonb](https://www.postgresql.org/docs/9.3/static/functions-json.html).

An example of a query that grabs a memory might look like:

```sql
SELECT user.id,
  memory.values->'current_balance' as balance,
  memory.values->'last_transaction_at' as last_transaction_at,
  memory.values->'last_transaction_status' as last_transaciton_status
  FROM users as user
    JOIN (
      SELECT memories.values AS values, memories.id AS id, memories.memoizable_id AS memoizable_id
        FROM memories
        WHERE memories.memoizable_type = 'user' 
        ORDER BY memories.created_at DESC 
      ) AS memory
    ON memory.memoizable_id = user.id
```

Note the arrow (->) syntax in the select clause. This peers into the json blob that contains the user's state the last time this record was memoized.


