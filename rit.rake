#Rake task
namespace :rit do

  desc "Import Redmine Issue Data From Remote Instance"
  task import: :environment do

    # Parameters that will be passed into the script
    import_project = 'SYS'
    id_start = 10000

    remote_configuration = {
      adapter:   "mysql2",
      host:      "localhost",
      username:  "redmine",
      password:  "my_password",
      database:  "sys_redmine_development"}

    #Script Start
    current_configuration = ActiveRecord::Base.configurations
    ActiveRecord::Base.establish_connection(**remote_configuration)

    ActiveRecord::Base.establish_connection(**current_configuration["development"].symbolize_keys)
  end
end

