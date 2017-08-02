class CreateMemories < ActiveRecord::Migration
  def change
    create_table :memories do |t|
      t.jsonb :values, null: false, default: '{}'
      t.string :state
      t.integer :created_by_id
      t.timestamps null: false
      t.references :memoizable, polymorphic: true
    end

    add_index :memories, [:memoizable_id, :memoizable_type]

    # gin is a postgres inverted index that's good with jsonb (BTREE_GIN)
    # https://www.postgresql.org/docs/9.5/static/gin.html
    add_index :memories, :values, using: :gin
  end
end
