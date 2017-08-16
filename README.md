# Redmine Issue Transfer (RIT)

## Redmine Setup

Redmine install steps
* Clone the [redmine](https://github.com/redmine/redmine) repository `git clone git@github.com:redmine/redmine.git`
* Move to the redmine directory `cd redmine`
* Set the git branch to version 3.3.3 `git checkout 3.3.3`
* Install the Ruby Gems by running `bundle install`
* Setup the database with `rake db:create db:migrate`

## Resetting / Loading Extreme Engineering Redmine instance

**Business Administrators:**`mysql -u <username> -p <redmine database name> < sql/redmine_ba_refresh.sql`
**System Administration:**`mysql -u <username> -p <redmine database name> < sql/redmine_sys_refresh.sql`

## Merging Resolution

This is the resolution for merging database tables from different projects that are not issues or directly linked to issues (e.g. TimeEntries).

### Terminology
**Current Redmine** The redmine instance we are importing data into
**Remote Redmine** The remine instance we are pulling data from

### Table Unique Identifies

These are the fields uniquely identifying a record besides the primary numeric id for each table. When we merge tables from different databases these are the fields we'll be using as identifiers.

* User - login
* Group (the User table) - lastname
* Project - identifier
* Role - name
* Email - address

### Merging Strategy

#### Union based on Unique Identifier

Tables: User, Email

In this strategy we'll only be adding only be adding records to a table if the record is not in the Current Redmine.

For example if the Current Redmine has email addresses foo@bar.com, moo@bar.com and the Remote Redmine has email addresses foo@bar.com, boo@bar.com then only boo@bar.com would be imported from the Remote Redmine

#### Suffix Addition

Tables: Role

For all the records of the Remote Redmine we'll be adding a suffix (e.g. SYS) to the end of the records Unique identifier. All Remote Redmine records will be imported over and tagged as coming from that instance

For example if the Current Remine has roles Manager and Admin and the Remote Redmine has roles Manager and SysAdmin and we are using SYS as the suffix then at the end of the import there would be Manager, Admin, Manager-SYS, and SysAdmin-SYS roles

#### Suffix Addition for name conflicts

Tables: Project

This works exactly like **Suffix Addition** except we'll only be adding the suffix if a records unique identifier exists in both the Current Redmine and the Remote Redmine

For example if the Current Remine has projects security and guppy and the Remote Redmine has projects security and flounder and we are using SYS as the suffix then at the end of the import there would be security, security-sys, guppy, and flounder projects

#### Group Merging (Suffix Addition)

Tables: Group

Groups will be merged using **Suffix Addition** except for groups which represent LDAP groups.

For example if there is a SysAdmin LDAP group and the Current Redmine has groups SysAdmin, quality, everyone the Remote Redmine has groups SysAdmin, quality, and support with a suffix of SYS then the merged groups will be SysAdmin, quality, quality-SYS, everyone, and support-SYS
