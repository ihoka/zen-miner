class CreateXmrigCommands < ActiveRecord::Migration[8.1]
  def change
    create_table :xmrig_commands do |t|
      t.string :hostname, null: false
      t.string :action, null: false
      t.string :status, null: false, default: "pending"
      t.text :reason
      t.text :result
      t.datetime :processed_at
      t.text :error_message

      t.timestamps

      t.index :hostname
      t.index [ :hostname, :status ]
      t.index [ :status, :created_at ]
    end
  end
end
