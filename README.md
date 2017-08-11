# Redmine Information Transfer (RIT)

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
