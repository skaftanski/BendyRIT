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
      new_email_address = e.dup
      new_email_address.user = nil

      acc[e.address] = new_email_address
      acc
    end

    users = User.eager_load(:email_address).all.reject { |u| current_users[u.login] }.inject(current_users.dup) do |acc, u|
      new_user = u.dup
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
      new_role = r.dup
      new_role.name = "#{r.name}-#{args.redmine_suffix}"

      acc[r.id] = new_role
      acc
    end

    trackers = Tracker.all.inject({}) do |acc, t|
      new_tracker = t.dup
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

    members_users = Member.joins(:user).where(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      new_member = m.dup
      new_member.user = users[m.user.login]
      new_member.principal = new_member.user

      acc[m.id] = new_member
      acc
    end

    members_groups = Member.joins(:principal).where.not(users: { type: ['User', 'AnonymousUser'] }).inject({}) do |acc, m|
      member_group = groups[m.principal.lastname] || groups[m.principal.lastname + '-' + args.redmine_suffix]
      new_member = m.dup
      new_member.principal = member_group

      acc[m.id] = new_member
      acc
    end

    members = members_users.merge(members_groups)

    member_roles = MemberRole.all.inject({}) do |acc, mr|
      new_member_role = mr.dup
      new_member_role.member = members[mr.member_id]
      new_member_role.role = roles[mr.role_id]

      acc[mr.id] = new_member_role
      acc
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
    # Set connection back to local database
    ActiveRecord::Base.establish_connection(**current_configuration)

    # Remove email notification callbacks
    EmailAddress.skip_callback(:create, :after, :deliver_security_notification_create)
    EmailAddress.skip_callback(:update, :after, :deliver_security_notification_update)

    puts ''
    puts "Importing Users"
    users.values.select { |u| u.id.nil? && !current_users[u.login] }.each do |u|
      puts "Importing User #{u.name} (login: #{u.login})"
      puts '-------------'
      begin
        u.save! if !args.dry_run
      rescue Exception => e
        puts 'User Import Error'
        puts e.message
        puts 'User'
        pp u

        throw e
      end
    end

    puts ''
    puts "Importing Roles"
    roles.values.reject(&:id).each do |r|
      puts "Importing Role #{r.name}"
      puts '-------------'
      begin
        r.save! if !args.dry_run
      rescue Exception => e
        puts 'Role Import Error'
        puts e.message
        puts 'Role'
        pp r

        throw e
      end
    end

    puts ''
    puts "Importing Issue Statuses"
    issue_statuses.values.each do |is|
      puts "Importing  #{is.name}"
      puts '-------------'
      begin
        is.save! if !args.dry_run
      rescue Exception => e
        puts 'Issue Status Import Error'
        puts e.message
        puts 'Issue Status'
        pp is

        throw e
      end
    end

    trackers.values.each { |t| t.default_status = issue_statuses[t.default_status_id] }

    puts ''
    puts "Importing Trackers"
    trackers.values.each do |t|
      puts "Importing Tracker #{t.name}"
      puts '-------------'
      begin
        t.save! if !args.dry_run
      rescue Exception => e
        puts 'Tracker Import Error'
        puts e.message
        puts 'Tracker'
        pp t

        throw e
      end
    end

    workflow_rules.each do |workflow|
      workflow.tracker = trackers[workflow.tracker_id]
      workflow.role = roles[workflow.role_id]
      workflow.old_status = issue_statuses[workflow.old_status_id] unless workflow.old_status_id == 0
      workflow.new_status = issue_statuses[workflow.new_status_id] unless workflow.new_status_id == 0
    end

    def logging_import(records, name, import_class, dry_run)
      puts ''
      total_records = records.length
      puts "Importing #{total_records} #{name}"
      record_block_num = [(total_records / 100), 100].max
      records_imported = 0
      import_class.transaction do
        records.map do |record|
          begin
            record.save! if !dry_run && record.new_record?
          rescue Exception => e
            puts"'#{name} Import Error"
            puts e.message
            puts name
            pp record

            throw e
          end
          records_imported = (records_imported + 1)
          if 0 == (records_imported % record_block_num)
            puts "#{records_imported} of #{total_records} #{(records_imported * 100) / total_records}%"
          end
        end
      end
    end

    logging_import(workflow_rules, 'Workflow Rules', WorkflowRule, args.dry_run)

    projects.values.select(&:parent_id).each { |p| p.parent = projects[p.parent_id]; p.parent_id = nil }

    issue_categories.each do |issue_category|
      issue_category.project = projects[issue_category.project_id]
      issue_category.assigned_to = users[issue_category.assigned_to.login] if issue_category.assigned_to
    end

    issue_categories.group_by(&:project).each do |p, ics|
      p.issue_categories = ics
    end

    versions.each { |v| v.project = projects[v.project_id] }
    versions.group_by(&:project).each { |p, vs| p.versions = vs }

    puts ''
    puts "Importing Projects"
    puts <<-PROJECTS
Projects have
  * #{issue_categories.length} Issue Categories
  * #{versions.length} Versions
PROJECTS
    projects.values.each do |p|
      puts "Importing Project #{p.name} (identifier: #{p.identifier})"
      puts '-------------'
      begin
        p.save! if (p.new_record? && !args.dry_run)
      rescue Exception => e
        puts 'Project Import Error'

        puts e.message
        puts 'Project'
        pp p

        puts 'Project Versions'
        puts '-------------'
        bad_versions = p.versions.reject { |v| v.errors.messages.empty?}
        puts 'Bad Project Verions' unless bad_versions.empty?
        bad_versions.each do |bv|
          pp bv.errors.full_messages
          pp bv
        end

        puts 'Good Project Verions'
        good_versions = p.versions.select { |v| v.errors.messages.empty?}
        good_versions.each { |gv| pp gv}

        puts 'Project Issue Categories'
        puts '-------------'
        bad_issue_categories = p.issue_categories.reject { |v| v.errors.messages.empty?}
        puts 'Bad Project Issue Category' unless bad_issue_categories.empty?
        bad_issue_categories.each do |bv|
          pp bv.errors.full_messages
          pp bv
        end

        puts 'Good Project Issue Category'
        good_issue_categories = p.issue_categories.select { |v| v.errors.messages.empty?}
        good_issue_categories.each { |gv| pp gv}

        throw e
      end
    end

    enumerations.values.select(&:parent_id).each { |e| e.parent = enumerations[e.parent_id]}
    enumerations.values.select(&:project_id).each { |e| e.project = projects[e.project_id]}

    puts ''
    puts "Importing Enumerations"
    enumerations.values.each do |e|
      puts "Importing Enumeration #{e.name}"
      puts '-------------'
      e.save! if !args.dry_run
    end

    members.values.each { |m| m.project = projects[m.project_id] }
    member_roles.values.select { |mr| mr.member}.group_by {|mr| mr.member }.each { |m, mrs| m.member_roles = mrs }

    # Remove memberRole add new member roles callbacks
    MemberRole.skip_callback(:create, :after, :add_role_to_group_users)
    MemberRole.skip_callback(:create, :after, :add_role_to_subprojects)

    logging_import(members.values, 'Members', Member, args.dry_run)
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
    Project
    class Project
      alias_method :active_activities, :activities

      def activities(include_inactive=false)
        self.active_activities(true)
      end
    end

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

      new_issue.created_on = i.created_on
      new_issue.updated_on = i.updated_on

      acc[new_issue.id] = new_issue
      acc
    end

    time_entries = TimeEntry.all.map do |te|
      new_time_entry = te.dup

      new_time_entry.created_on = te.created_on
      new_time_entry.updated_on = te.updated_on

      new_time_entry
    end

    attachments = Attachment.all.map do |a|
      new_attachment = a.dup

      new_attachment.created_on = a.created_on

      new_attachment
    end

    issue_relations = IssueRelation.all.map(&:dup)
    watchers = Watcher.joins(:user).where(watchable_type: 'Issue', users: {status: User::STATUS_ACTIVE}).all.map(&:dup)

    journals = Journal.eager_load(:details).all.map do |j|
      new_journal = j.dup
      new_journal.user = user_id_map[j.user_id]
      new_journal.details = j.details.map(&:dup)
      new_journal.details.each { |jd| jd.journal = new_journal }

      new_journal.created_on = j.created_on

      new_journal
    end

    # Set connection back to local database
    ActiveRecord::Base.record_timestamps = false
    ActiveRecord::Base.establish_connection(**current_configuration)

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

      issue.lft = nil
      issue.rgt = nil

      issue.parent = issues[issue.parent_id]
      issue.author = user_id_map[issue.author_id]
      issue.assigned_to = user_id_map[issue.assigned_to_id]
      issue.status = status
      issue.priority =  enumeration_id_map[issue.priority_id]

      issue.instance_variable_set(:@assignable_versions, issue.project.shared_versions)
    end

    # Remove Unnecessary active record callbacks
    def logging_import(records, name, import_class, dry_run)
      puts ''
      total_records = records.length
      puts "Importing #{total_records} #{name}"
      record_block_num = [(total_records / 100), 100].max
      records_imported = 0
      import_class.transaction do
        records.map do |record|
          begin
            record.save! if !dry_run && record.new_record?
          rescue Exception => e
            puts"'#{name} Import Error"
            puts e.message
            puts name
            pp record

            throw e
          end
          records_imported = (records_imported + 1)
          if 0 == (records_imported % record_block_num)
            puts "#{records_imported} of #{total_records} #{(records_imported * 100) / total_records}%"
          end
        end
      end
    end

    Issue.skip_callback(:save, :before, :close_duplicates)
    Issue.skip_callback(:save, :before, :force_updated_on_change)

    Issue.skip_callback(:create, :after, :send_notification)

    logging_import(issues.values, 'Issues', Issue, args.dry_run)

    issue_relations.group_by(&:issue_from_id).each do |issue_id, from_issues|
      issue = issues[issue_id_map[issue_id]]
      from_issues.each { |ij| ij.issue_from = issue }
    end

    issue_relations.group_by(&:issue_to_id).each do |issue_id, to_issues|
      issue = issues[issue_id_map[issue_id]]
      to_issues.each { |ij| ij.issue_to = issue }
    end

    logging_import(issue_relations, 'Issue Relations', IssueRelation, args.dry_run)

    time_entries.each do |time_entry|
      time_entry.project = project_id_map[time_entry.project_id]
      time_entry.user = user_id_map[time_entry.user_id]

      time_entry.activity =  enumeration_id_map[time_entry.activity_id]
    end

    time_entries.group_by(&:issue_id).each do |issue_id, entries|
      issue = issues[issue_id_map[issue_id]]
      entries.each { |e| e.issue = issue }
    end

    logging_import(time_entries, 'Time Entries', TimeEntry, args.dry_run)

    attachments.each { |a| a.author =  user_id_map[a.author_id] }

    attachments.group_by(&:container_id).each do |issue_id, issue_attachments|
      issue = issues[issue_id_map[issue_id]]
      issue_attachments.each { |ij| ij.container = issue }
    end

    logging_import(attachments, 'Attachments', Attachment, args.dry_run)

    watchers.each { |w| w.user = user_id_map[w.user_id] }
    watchers.group_by(&:watchable_id).each do |issue_id, watched_issues|
      issue = issues[issue_id_map[issue_id]]
      next if issue.nil?
      watched_issues.each { |wi| wi.watchable_id = issue.id }
    end

    logging_import(watchers, 'Watchers', Watcher, args.dry_run)

    journals.group_by(&:journalized_id).each do |issue_id, issue_journals|
      issue = issues[issue_id_map[issue_id]]
      issue_journals.each { |ij| ij.issue = issue }
    end

    Journal.skip_callback(:create, :before, :split_private_notes)
    Journal.skip_callback(:create, :after, :send_notification)

    logging_import(journals, 'Journals', Journal, args.dry_run)

    ActiveRecord::Base.record_timestamps = true
  end
end

