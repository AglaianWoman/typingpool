#!/usr/bin/env ruby

require 'audibleturk/test'
require 'fileutils'

class CollectProjectFixtureGen2 < Audibleturk::Test::Script
  def test_populate_fixture
    fixture_path = File.join(fixtures_dir, 'vcr', 'tp-collect-1')
    tp_collect(tp_collect_fixture_project_dir, fixture_path)
    assert(File.exists?("#{fixture_path}.yml"))
    add_goodbye_message("Initial tp-collect recorded. Please complete and approve two more assignments and run make_tp_collect_fixture_3.rb. Check for assignments at\nhttps://workersandbox.mturk.com/mturk/searchbar?minReward=0.00&searchWords=typingpooltest&selectedSearchType=hitgroups\n...and then approve them at\nhttps://requestersandbox.mturk.com/mturk/manageHITs?hitSortType=CREATION_DESCENDING&%2Fsort.x=11&%2Fsort.y=7")
  end
end
