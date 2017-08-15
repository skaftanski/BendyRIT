#Rake task
require 'set'
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
    user_ids = Set.new(User.all.map(&:login))
    current_emails = EmailAddress.all.inject({}) {|acc, ce| acc[ce.address] = ce; acc }

    current_configuration = ActiveRecord::Base.configurations
    # Set connection to remote database
    ActiveRecord::Base.establish_connection(**remote_configuration)

    projects = Project.all.map do |p|
      new_project = Project.new(p.attributes.dup.except(:id, :status))
      new_project.status = p.status
      new_project.name = "#{p.name}-#{import_project}"
      new_project.identifier = "#{p.identifier}-#{import_project.downcase}"
      new_project

    end

    emails = EmailAddress.all.reject { |e| current_emails[e.address] }.inject(current_emails.dup) do |acc, e|
      new_email_address = EmailAddress.new(e.attributes.dup.except(:id, :user))
      acc[e.address] = new_email_address
      acc
    end

    users = User.all.reject { |u| user_ids.include?(u.login) } .map do |u|
      new_user = u.class.new(u.attributes.dup.except(:id))
      new_user.login = u.login
      new_user.email_address = emails[u.email_address.address] if u.email_address
      new_user.email_addresses = u.email_addresses.map { |ea| emails[ea.address] }
      new_user
    end

    # Set connection back to local database
    ActiveRecord::Base.establish_connection(**current_configuration["development"].symbolize_keys)

    # Remove email notification callbacks
    EmailAddress.skip_callback(:create, :after, :deliver_security_notification_create)
    EmailAddress.skip_callback(:update, :after, :deliver_security_notification_update)
    users.each { |u| u.save! }
    # projects.each {|p| p.save!}
  end
end

