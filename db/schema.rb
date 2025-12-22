# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_12_22_104303) do
  create_table "xmrig_commands", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "hostname", null: false
    t.datetime "processed_at"
    t.text "reason"
    t.text "result"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["hostname", "status"], name: "index_xmrig_commands_on_hostname_and_status"
    t.index ["hostname"], name: "index_xmrig_commands_on_hostname"
    t.index ["status", "created_at"], name: "index_xmrig_commands_on_status_and_created_at"
  end

  create_table "xmrig_processes", force: :cascade do |t|
    t.integer "accepted_shares"
    t.datetime "created_at", null: false
    t.integer "error_count", default: 0
    t.float "hashrate"
    t.text "health_data"
    t.string "hostname", null: false
    t.text "last_error"
    t.datetime "last_health_check_at"
    t.integer "pid"
    t.integer "rejected_shares"
    t.integer "restart_count", default: 0
    t.datetime "started_at"
    t.string "status", default: "stopped", null: false
    t.datetime "stopped_at"
    t.datetime "updated_at", null: false
    t.string "worker_id", null: false
    t.index ["hostname"], name: "index_xmrig_processes_on_hostname", unique: true
  end
end
