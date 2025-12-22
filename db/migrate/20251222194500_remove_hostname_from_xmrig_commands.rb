class RemoveHostnameFromXmrigCommands < ActiveRecord::Migration[8.1]
  def change
    remove_index :xmrig_commands, :hostname
    remove_index :xmrig_commands, [ :hostname, :status ]
    remove_column :xmrig_commands, :hostname, :string, null: false
  end
end
