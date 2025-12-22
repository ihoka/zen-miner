class CreateXmrigProcesses < ActiveRecord::Migration[8.1]
  def change
    create_table :xmrig_processes do |t|
      t.integer :pid
      t.string :status, null: false, default: "stopped"
      t.string :worker_id, null: false
      t.string :hostname, null: false
      t.datetime :started_at
      t.datetime :stopped_at
      t.integer :error_count, default: 0
      t.text :last_error
      t.datetime :last_health_check_at
      t.integer :restart_count, default: 0
      t.float :hashrate
      t.integer :accepted_shares
      t.integer :rejected_shares
      t.text :health_data

      t.timestamps

      t.index :hostname, unique: true
    end
  end
end
