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
    project_ids = Set.new(Project.all.map(&:identifier))
    ldap_groups = Set.new([])
    current_groups = Group.where(lastname: ldap_groups).inject({}) { |acc, cg| acc[cg.lastname] = cg; acc }
    current_users = User.all.inject({}) { |acc, cu| acc[cu.login] = cu; acc }
    current_emails = EmailAddress.all.inject({}) {|acc, ce| acc[ce.address] = ce; acc }

    current_configuration = ActiveRecord::Base.configurations
    # Set connection to remote database
    ActiveRecord::Base.establish_connection(**remote_configuration)
    # Import Sets that can intersect
    emails = EmailAddress.all.reject { |e| current_emails[e.address] }.inject(current_emails.dup) do |acc, e|
      new_email_address = EmailAddress.new(e.attributes.dup.except(:id, :user))

      acc[e.address] = new_email_address
      acc
    end

    users = User.all.reject { |u| current_users[u.login] }.inject(current_users.dup) do |acc, u|
      new_user = u.class.new(u.attributes.dup.except(:id))
      new_user.login = u.login
      new_user.email_address = emails[u.email_address.address] if u.email_address
      new_user.email_addresses = u.email_addresses.map { |ea| emails[ea.address] }

      acc[u.login] = new_user
      acc
    end

    groups = Group.where.not(lastname: ldap_groups).inject(current_groups.dup) do |acc, g|
      new_group = Group.new(g.attributes.dup.except(:id))
      new_group.lastname = "#{g.lastname}-#{import_project}"
      new_group.users = g.users.pluck(:login).map { |login| users[login] }

      acc[new_group.lastname] = new_group
      acc
    end
    # Import Sets the are disjoint
    roles = Role.all.inject({}) do |acc, r|
      new_role = Role.new(r.attributes.dup.except(:id))
      new_role.name = "#{r.name}-#{import_project}"

      acc[r.id] = new_role
      acc
    end

    projects = Project.all.inject({}) do |acc, p|
      new_project = Project.new(p.attributes.dup.except(:id, :status))
      new_project.lft = nil
      new_project.rgt = nil
      new_project.status = p.status
      new_project.name = "#{p.name}-#{import_project}"
      new_project.identifier = "#{p.identifier}-#{import_project.downcase}" if project_ids.include?(p.identifier)

      acc[p.id] = new_project
      acc
    end
    # Link up associations
    projects.values.select { |p| p.parent }.each { |p| p.parent = projects[p.parent_id] }
    members_users = Member.joins(:user).where(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      member_attributes = {project: projects[m.project_id], user: users[m.user.login], mail_notification: m.mail_notification}
      new_member = Member.new(member_attributes)

      acc[m.id] = new_member
      acc
    end

    members_groups = Member.joins(:principal).where.not(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      member_group = groups[m.principal.lastname] || groups[m.principal.lastname + '-' + import_project]
      member_attributes = {project: projects[m.project_id], principal: member_group, mail_notification: m.mail_notification}
      new_member = Member.new(member_attributes)

      acc[m.id] = new_member
      acc
    end

    members = members_users.merge(members_groups)
    members.values.group_by {|m| m.project }.each { |p, ms| p.memberships = ms }

    member_roles = MemberRole.all.inject({}) do |acc, mr|
      member_role_attributes = {member: members[mr.member_id], role: roles[mr.role_id], inherited_from: mr.inherited_from}
      new_member_role = MemberRole.new(member_role_attributes)

      acc[mr.id] = new_member_role
      acc
    end

    member_roles.values.select { |mr| mr.member}.group_by {|mr| mr.member }.each { |m, mrs| m.member_roles = mrs }
    # Set connection back to local database
    ActiveRecord::Base.establish_connection(**current_configuration["development"].symbolize_keys)

    # Remove email notification callbacks
    EmailAddress.skip_callback(:create, :after, :deliver_security_notification_create)
    EmailAddress.skip_callback(:update, :after, :deliver_security_notification_update)

    projects.values.each { |p| p.save! if p.new_record? }
  end
end

