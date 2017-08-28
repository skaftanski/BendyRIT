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
    # Import Sets that are disjoint
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

    versions = Version.all.map do |v|
      new_version = v.dup
      new_version.name = "#{v.name}-#{args.redmine_suffix}"
      new_version
    end

    projects = Project.all.inject({}) do |acc, p|
      project_trackers = p.trackers.pluck(:id).map { |id| trackers[id] }
      new_project = p.dup
      new_project.trackers = project_trackers
      new_project.enabled_modules = p.enabled_modules.map(&:dup)
      new_project.enabled_modules.each { |em| em.project = new_project }

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
      issue_category.assigned_to = users[issue_category.assigned_to.login] if issue_category.assigned_to
    end

    issue_categories.group_by(&:project).each do |p, ics|
      p.issue_categories = ics
    end

    versions.each { |v| v.project = projects[v.project_id] }
    versions.group_by(&:project).each { |p, vs| p.versions = vs }

    enumerations.values.select(&:parent_id).each { |e| e.parent = enumerations[e.parent_id]}
    enumerations.values.select(&:project_id).each { |e| e.project = projects[e.project_id]}

    members_users = Member.joins(:user).where(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      new_member = m.dup
      new_member.project = projects[m.project_id]
      new_member.user = users[m.user.login]
      new_member.principal = new_member.user

      acc[m.id] = new_member
      acc
    end

    members_groups = Member.joins(:principal).where.not(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      member_group = groups[m.principal.lastname] || groups[m.principal.lastname + '-' + args.redmine_suffix]
      new_member = m.dup
      new_member.project = projects[m.project_id]
      new_member.principal = member_group

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

    enumerations.values.select(&:project).each { |e| e.project_id = e.project.id }
    puts ''
    puts "Importing Enumerations"
    enumerations.values.each do |e|
      puts "Importing Enumeration #{e.name}"
      puts '-------------'
      e.save! if !args.dry_run
    end

    puts ''
    puts "Importing Issue Statuses not associated with projects"
    issue_statuses.values.select { |is| is.id.nil? }.each do |is|
      puts "Importing Issue Status #{is.name}"
      puts '-------------'
      is.save! if !args.dry_run
    end

    puts ''
    puts "Importing Users not associated with projects"
    users.values.select { |u| u.id.nil? && !current_users[u.login] }.each do |u|
      puts "Importing User Status #{u.name} (login: #{u.login})"
      puts '-------------'
      u.save! if !args.dry_run
    end
  end

  desc "Import Redmine Issue Data From Remote Instance. Usage: rake rit:issue_import -- [options]"
  task issue_import: :environment do
    # Command Line arguements
    opts.banner = "Usage: rake rit:issue_import -- [options]"

    opts.on('-s', '--suffix redmine_suffix', 'Suffix to be added to Redmine Projects being imported') do |rs|
      args.redmine_suffix = rs.strip.upcase
    end

    opts.on('-i', '--issue-id issue_id_start', OptParse::DecimalInteger, 'Starting id for Remote Redmine issue imports') do |isi|
      args.issue_id_start = isi
      if args.issue_id_start <= 0
        puts "Starting Issue Id must be greater then or equal to 0 (e.g. 1, 250, 10,000)"
      end
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
    elsif args.issue_id_start.blank?
      puts 'Redmine Issue Id Start required'
      puts opts
      exit
    end

    # Loading Current Issue relation tables
    current_groups = Group.all.inject({}) { |acc, cg| acc[cg.lastname] = cg; acc }
    current_users = User.all.inject({}) { |acc, cu| acc[cu.login] = cu; acc }
    current_trackers = Tracker.all.inject({}) { |acc, ct| acc[ct.name] = ct; acc }
    current_issue_statuses = IssueStatus.all.inject({}) { |acc, cis| acc[cis.name] = cis; acc }
    current_versions = Version.all.inject({}) { |acc, cv| acc[cv.name] = cv; acc }
    current_projects = Project.all.inject({}) { |acc, cp| acc[cp.identifier] = cp; acc }

    current_enumerations = Enumeration.all.inject({}) { |acc, ce| acc[ce.name] = ce; acc  }
    current_configuration = ActiveRecord::Base.configurations[Rails.env].symbolize_keys

    puts "-----DRY RUN-----" if args.dry_run
    puts "Importing Data into #{current_configuration[:database]}"
    # Set connection to remote database
    ActiveRecord::Base.establish_connection(**args.database_params)
    puts 'Loading Remote Issues and related data'

    # Maps from Remote ID to Local
    project_id_map = Project.all.inject({nil: nil}) do |acc, p|
      acc[p.id] = current_projects["#{p.identifier}-#{args.redmine_suffix.downcase}"] || current_projects[p.identifier]
      acc
    end

    user_id_map = User.all.inject({nil: nil}) do |acc, u|
      acc[u.id] = current_users[u.login] || current_groups[u.lastname]
      acc
    end

    enumeration_id_map = Enumeration.all.inject({nil: nil}) do |acc, e|
      acc[e.id] = current_enumerations["#{e.name}-#{args.redmine_suffix}"]
      acc
    end

    issue_status_id_map = IssueStatus.all.inject({nil: nil}) do |acc, is|
      acc[is.id] = current_issue_statuses["#{is.name}-#{args.redmine_suffix}"]
      acc
    end

    version_id_map = Version.all.inject({nil: nil}) do |acc, v|
      acc[v.id] = current_versions["#{v.name}-#{args.redmine_suffix}"]
      acc
    end

    tracker_id_map = Tracker.all.inject({nil: nil}) do |acc, t|
      acc[t.id] = current_trackers["#{t.name}-#{args.redmine_suffix}"]
      acc
    end
    # Import Sets the are disjoint
    issue_id_map = Issue.pluck(:id).inject({}) { |acc, iid| acc[iid] = args.issue_id_start + iid; acc }

    issues = Issue.eager_load(:project, :tracker, :status, :author, :assigned_to).all.inject({}) do |acc, i|
      new_issue = i.dup
      new_issue.id = issue_id_map[i.id]
      new_issue.root_id = issue_id_map[i.root_id]
      new_issue.parent_id = issue_id_map[i.parent_id]

      acc[new_issue.id] = new_issue
      acc
    end

    time_entries = TimeEntry.all.map(&:dup)
    attachments = Attachment.all.map(&:dup)
    issue_relations = IssueRelation.all.map(&:dup)

    journals = Journal.eager_load(:details).all.map do |j|
      new_journal = j.dup
      new_journal.user = user_id_map[j.user_id]
      new_journal.details = j.details.map(&:dup)
      new_journal.details.each { |jd| jd.journal = new_journal }

      new_journal
    end
    # Set up relations
    puts 'Setting up relations between issues and related data'
    issues.values.each do |issue|
      # Chnaging project overwrites fixed_version and tracker
      version =  version_id_map[issue.fixed_version_id]
      tracker = tracker_id_map[issue.tracker_id]

      # Changing the tracker changes the status to nil
      status = issue_status_id_map[issue.status_id]

      issue.project = project_id_map[issue.project_id]

      issue.fixed_version = version
      issue.tracker = tracker

      issue.parent = issues[issue.parent_id]
      issue.author = user_id_map[issue.author_id]
      issue.assigned_to = user_id_map[issue.assigned_to_id]
      issue.status = status
      issue.priority =  enumeration_id_map[issue.priority_id]
    end

    time_entries.each do |time_entry|
      time_entry.project = project_id_map[time_entry.project_id]
      time_entry.user = user_id_map[time_entry.user_id]

      time_entry.activity =  enumeration_id_map[time_entry.activity_id]
    end

    time_entries.group_by(&:issue_id).each do |issue_id, entries|
      issue = issues[issue_id_map[issue_id]]
      entries.each { |e| e.issue = issue }
      issue.time_entries = entries
    end

    attachments.each { |a| a.author =  user_id_map[a.author_id] }
    attachments.group_by(&:container_id).each do |issue_id, issue_attachments|
      issue = issues[issue_id_map[issue_id]]
      issue_attachments.each { |ij| ij.container = issue }
      issue.attachments = issue_attachments
    end

    issue_relations.group_by(&:issue_from_id).each do |issue_id, from_issues|
      issue = issues[issue_id_map[issue_id]]
      from_issues.each { |ij| ij.issue_from = issue }
      issue.relations_from = from_issues
    end

    issue_relations.group_by(&:issue_to_id).each do |issue_id, to_issues|
      issue = issues[issue_id_map[issue_id]]
      to_issues.each { |ij| ij.issue_to = issue }
      issue.relations_to = to_issues
    end

    journals.group_by(&:journalized_id).each do |issue_id, issue_journals|
      issue = issues[issue_id_map[issue_id]]
      issue_journals.each { |ij| ij.issue = issue }
      issue.journals = issue_journals
    end

    # Set connection back to local database
    ActiveRecord::Base.establish_connection(**current_configuration)

    # Remove Unnecessary active record callbacks
    Issue.skip_callback(:save, :before, :close_duplicates)

    Issue.skip_callback(:save, :after, :update_parent_attributes)

    Issue.skip_callback(:create, :after, :send_notification)

    puts ''
    total_issues = issues.length
    puts "Importing #{total_issues} Issues"
    issue_block_num = [(total_issues / 100), 100].max
    issues_imported = 0
    issues.values.map do |issue|
      issue.save! if !args.dry_run
      issues_imported = (issues_imported + 1)
      if 0 == (issues_imported % issue_block_num)
        puts "#{issues_imported} of #{total_issues} #{(issues_imported * 100) / total_issues}%"
      end
    end
  end
end

