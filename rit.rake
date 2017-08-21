# Rake task
require 'optparse'
require 'set'
require 'yaml'


namespace :rit do

  Options = Struct.new(:database_params, :redmine_suffix, :issue_id_start, :dry_run)
  args = Options.new(dry_run: false)

  opts = OptionParser.new()
  opts.on('-r', '--remote-database-params remote_database_params', 'File for database Paramters') do |dp_file|
    if File.exists?(dp_file)
      args.database_params = YAML::load_file(dp_file).symbolize_keys
    else
      puts "#{dp_file} does not exist"
      exit
    end
  end

  opts.on('-d', '--dry-run', 'Dry run of Project Import') do |dry|
    args.dry_run = true
  end

  desc "Import Project data for issues From Remote Instance. Usage: rake rit project_import -- options"
  task project_import: :environment do
    # Command Line arguements
    opts.banner = "Usage: rake rit:project_import -- [options]"

    opts.on('-s', '--suffix redmine_suffix', 'Suffix to be added to Redmine Projects being imported') do |rs|
      args.redmine_suffix = rs.strip.upcase
    end

    opts.on('-h', '--help', 'Help') do
      puts opts
      exit
    end

    opts.parse!(opts.order!(ARGV) {})

    if args.database_params.blank?
      puts 'Remote Database Parameter File required'
      puts opts
      exit
    elsif args.redmine_suffix.blank?
      puts 'Redmine Suffix required'
      puts opts
      exit
    end

    # Constants
    ldap_groups = Set.new([])
    #Script Start
    project_ids = Set.new(Project.all.map(&:identifier))
    builtin_roles = Role.where.not(builtin: 0).inject({}) { |acc, br| acc[br.id] = br; acc }
    current_groups = Group.where(lastname: ldap_groups).inject({}) { |acc, cg| acc[cg.lastname] = cg; acc }
    current_users = User.all.inject({}) { |acc, cu| acc[cu.login] = cu; acc }
    current_emails = EmailAddress.all.inject({}) {|acc, ce| acc[ce.address] = ce; acc }

    current_configuration = ActiveRecord::Base.configurations[Rails.env].symbolize_keys

    puts "-----DRY RUN-----" if args.dry_run
    puts "Importing Data into #{current_configuration[:database]}"
    # Set connection to remote database
    ActiveRecord::Base.establish_connection(**args.database_params)
    puts 'Loading Remote data'
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
      new_group.lastname = "#{g.lastname}-#{args.redmine_suffix}"
      new_group.users = g.users.pluck(:login).map { |login| users[login] }

      acc[new_group.lastname] = new_group
      acc
    end
    # Import Sets the are disjoint
    roles = Role.where(builtin: 0).inject(builtin_roles.dup) do |acc, r|
      new_role = Role.new(r.attributes.dup.except(:id))
      new_role.name = "#{r.name}-#{args.redmine_suffix}"

      acc[r.id] = new_role
      acc
    end

    trackers = Tracker.all.inject({}) do |acc, t|
      new_tracker = Tracker.new(t.attributes.dup.except(:id))
      new_tracker.name = "#{t.name}-#{args.redmine_suffix}"

      acc[t.id] = new_tracker
      acc
    end

    issue_statuses = IssueStatus.all.inject({}) do |acc, is|
      new_issue_status = is.dup
      new_issue_status.name = "#{is.name}-#{args.redmine_suffix}"

      acc[is.id] = new_issue_status
      acc
    end

    enumerations = Enumeration.all.inject({}) do |acc, e|
      new_enumeration = e.dup
      new_enumeration.name = "#{e.name}-#{args.redmine_suffix}"

      acc[e.id] = new_enumeration
      acc
    end

    workflow_rules = WorkflowRule.all.map(&:dup)
    issue_categories = IssueCategory.all.map do |ic|
      new_issue_category = ic.dup
      new_issue_category.name = "#{ic.name}-#{args.redmine_suffix}"
      new_issue_category
    end

    projects = Project.all.inject({}) do |acc, p|
      project_trackers = p.trackers.pluck(:id).map { |id| trackers[id] }
      new_project = p.dup
      new_project.trackers = project_trackers
      new_project.lft = nil
      new_project.rgt = nil
      new_project.status = p.status
      new_project.name = "#{p.name}-#{args.redmine_suffix}"
      new_project.identifier = "#{p.identifier}-#{args.redmine_suffix.downcase}" if project_ids.include?(p.identifier)

      acc[p.id] = new_project
      acc
    end
    # Link up associations
    projects.values.select { |p| p.parent }.each { |p| p.parent = projects[p.parent_id] }
    projects.values.each { |p| p.enabled_modules = p.enabled_modules.map { |em| EnabledModule.new(em.attributes.dup.except(:id)) } }

    trackers.values.each { |t| t.default_status = issue_statuses[t.default_status_id] }

    workflow_rules.each do |workflow|
      workflow.tracker = trackers[workflow.tracker_id]
      workflow.role = roles[workflow.role_id]
      workflow.old_status = issue_statuses[workflow.old_status_id] unless workflow.old_status_id == 0
      workflow.new_status = issue_statuses[workflow.new_status_id] unless workflow.new_status_id == 0
    end

    workflow_rules.group_by(&:tracker).each do |t, wfrs|
      t.workflow_rules = wfrs
    end

    issue_categories.each do |issue_category|
      issue_category.project = projects[issue_category.project_id]
      issue_category.assigned_to = users[issue_category.assigned_to.id] if issue_category.assigned_to
    end

    issue_categories.group_by(&:project).each do |p, ics|
      p.issue_categories = ics
    end

    enumerations.values.select(&:parent_id).each { |e| e.parent = enumerations[e.parent_id]}
    enumerations.values.select(&:project_id).each { |e| e.project = projects[e.project_id]}

    members_users = Member.joins(:user).where(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      member_attributes = {project: projects[m.project_id], user: users[m.user.login], mail_notification: m.mail_notification}
      new_member = Member.new(member_attributes)

      acc[m.id] = new_member
      acc
    end

    members_groups = Member.joins(:principal).where.not(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      member_group = groups[m.principal.lastname] || groups[m.principal.lastname + '-' + args.redmine_suffix]
      member_attributes = {project: projects[m.project_id], principal: member_group, mail_notification: m.mail_notification}
      new_member = Member.new(member_attributes)

      acc[m.id] = new_member
      acc
    end

    members = members_users.merge(members_groups)
    members.values.group_by {|m| m.project }.each { |p, ms| p.memberships = ms }

    member_roles = MemberRole.all.inject({}) do |acc, mr|
      member_role_attributes = {member: members[mr.member_id], role: roles[mr.role_id]}
      new_member_role = MemberRole.new(member_role_attributes)

      acc[mr.id] = new_member_role
      acc
    end

    member_roles.values.select { |mr| mr.member}.group_by {|mr| mr.member }.each { |m, mrs| m.member_roles = mrs }
    # Set connection back to local database
    ActiveRecord::Base.establish_connection(**current_configuration)

    # Remove email notification callbacks
    EmailAddress.skip_callback(:create, :after, :deliver_security_notification_create)
    EmailAddress.skip_callback(:update, :after, :deliver_security_notification_update)

    puts ''
    puts "Importing Projects"
    projects.values.each do |p|
      puts "Importing Project #{p.name} (identifier: #{p.identifier})"
      puts '-------------'
      p.save! if (p.new_record? && !args.dry_run)
    end

    puts ''
    puts "Importing Enumerations"
    enumerations.values.each do |e|
      puts "Importing Enumeration #{e.name}"
      puts '-------------'
      e.save!
    end
  end

  desc "Import Redmine Issue Data From Remote Instance"
  task issue_import: :environment do
  end
end

