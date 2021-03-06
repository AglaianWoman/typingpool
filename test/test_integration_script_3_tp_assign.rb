#!/usr/bin/env ruby

$LOAD_PATH.unshift File.join(File.dirname(File.dirname(__FILE__)), 'lib')

require 'minitest/autorun'
require 'typingpool'
require 'typingpool/test'
require 'typingpool/utility/test'
include Typingpool::Utility::Test

class TestTpAssign < Typingpool::Test::Script

  #TODO: test that qualifications are sent (will need heroic effort
  #(or at least some xml parsing) since rturk doesn't provide an
  #easy way to look at HIT qualifications)
  def test_abort_with_no_input
    assert_raises(Typingpool::Error::Shell){call_script('tp-assign','--sandbox')}
  end

  def test_abort_with_no_template
    assert_tp_assign_abort_match([project_default[:title]], /Missing\b[^\n\r\f]*\btemplate/i)
  end

  def test_abort_with_bad_timespec
    assert_tp_assign_abort_match([project_default[:title], assign_default[:template], '--lifetime', '4u'], /can't convert/i)
  end

  def test_abort_with_bad_qualification
    assert_tp_assign_abort_match([project_default[:title], assign_default[:template], '--qualify', 'approval_rate &= 8'], /\bsense of --qualify.+\bunknown comparator\b/i)
    assert_tp_assign_abort_match([project_default[:title], assign_default[:template], '--qualify', 'fake_rate > 8'], /\bsense of --qualify\b.+unknown\b[^\n\r\f]*\btype\b/i)
  end

  def test_abort_with_bad_reward
    assert_tp_assign_abort_match([project_default[:title], assign_default[:template], '--reward', 'foo'], /sense of --reward/i)
  end

  
  def test_abort_with_sftp_http_url
    with_temp_readymade_project do |dir|
      config = Typingpool::Config.file(config_path(dir))
      config.to_hash['sftp'] = {
        'user' => 'test',
        'host' => 'example.com',
        'url' => 'http://example.com/foobar'
      }
      write_config(dir, config)
      exception = assert_raises(Typingpool::Error::Shell) do
        call_script('tp-assign','--sandbox', project_default[:title], assign_default[:template], '--config', config_path(dir))
      end
      assert_match(/must begin with 'https'/i, exception.message)
    end #with_temp_readymade_project do |dir|
  end
  
  def assert_tp_assign_abort_match(args, regex)
    assert_script_abort_match(args, regex) do |new_args|
      call_script('tp-assign', '--sandbox', *new_args)
    end
  end

  def test_tp_assign
    skip_if_no_amazon_credentials('tp-assign integration test')
    skip_if_no_s3_credentials('tp-assign integration test')
    with_temp_readymade_project do |dir|
      project = Typingpool::Project.new(project_default[:title], Typingpool::Config.file(config_path(dir)))
      vcr_names = ['tp_assign_1', 'tp_assign_2']
      copy_tp_assign_fixtures(dir, vcr_names[0])
      config = Typingpool::Config.file(config_path(dir))
      Typingpool::Amazon.setup(:sandbox => true, :config => Typingpool::Config.file(config_path(dir)))
      with_vcr(vcr_names[1], config, {
                 :preserve_exact_body_bytes => true,
                 :match_requests_on => [:method, vcr_core_host_matcher]
               }) do
        begin
          assign_time = (Typingpool::Test.record || Typingpool::Test.live) ? Time.now : project_time(project)
          tp_assign_with_vcr(dir, vcr_names[0])
          results = nil
          refute_empty(results = Typingpool::Amazon::HIT.all_for_project(project.local.id))
          assert_equal(project.local.subdir('audio','chunks').to_a.size, results.size)
          assert_equal(Typingpool::Utility.timespec_to_seconds(assign_default[:deadline]), results[0].full.assignments_duration.to_i)
          #These numbers will be apart due to clock differences and
          #timing vagaries of the assignment.
          assert_in_delta((assign_time + Typingpool::Utility.timespec_to_seconds(assign_default[:lifetime])).to_f, results[0].full.expires_at.to_f, 360) if Typingpool::Test.live
          keywords = results[0].at_amazon.keywords
          assign_default[:keyword].each{|keyword| assert_includes(keywords, keyword)}
          sandbox_csv = project.local.file('data', 'sandbox-assignment.csv').as(:csv)
          refute_empty(assignment_urls = sandbox_csv.map{|assignment| assignment['assignment_url'] })
          assert(assignment_html = Typingpool::Utility.fetch_url(assignment_urls.first).body)
          assert_match(/\b22[\s-]+second\b/, assignment_html)
          assert_all_assets_have_upload_status(sandbox_csv, 'assignment', 'yes')
        ensure
          tp_finish(dir) if (Typingpool::Test.record || Typingpool::Test.live)
        end #begin
        assert_empty(Typingpool::Amazon::HIT.all_for_project(project.local.id))
      end #with_vcr do...
    end #with_temp_readymade_project do...
  end

  def test_uploads_audio_when_needed
    skip_if_no_amazon_credentials('tp-assign unuploaded audio integration test')
    skip_if_no_s3_credentials('tp-assign unuploaded audio integration test')
    with_temp_readymade_project do |dir|
      project = Typingpool::Project.new(project_default[:title], Typingpool::Config.file(config_path(dir)))
      vcr_name = 'tp_assign_3'
      copy_tp_assign_fixtures(dir, vcr_name)
      csv = project.local.file('data', 'assignment.csv').as(:csv)
      if (Typingpool::Test.record || Typingpool::Test.live)
        assert_empty(csv.select{|assignment| Typingpool::Utility.working_url? assignment['audio_url']})
      end
      csv.each{|assignment| assert_empty(assignment['audio_uploaded'].to_s) }
      begin
        tp_assign_with_vcr(dir, vcr_name)
        sandbox_csv = project.local.file('data', 'sandbox-assignment.csv').as(:csv)
        assert_equal(csv.count, sandbox_csv.count)
        if (Typingpool::Test.record || Typingpool::Test.live)
          assert_equal(sandbox_csv.count, sandbox_csv.select{|assignment| working_url_eventually? assignment['audio_url'] }.count) 
        end
        assert_all_assets_have_upload_status(csv, 'audio', 'yes')
      ensure
        tp_finish(dir) if (Typingpool::Test.record || Typingpool::Test.live)
      end #begin
    end #with_temp_readymade_project do...
  end

  def test_fixing_failed_assignment_html_upload
    skip_if_no_amazon_credentials('tp-assign failed assignment upload integration test')
    skip_if_no_s3_credentials('tp-assign failed assignment upload integration test')
    with_temp_readymade_project do |dir|
      config = reconfigure_for_s3(Typingpool::Config.file(config_path(dir)))
      good_config_path = write_config(dir, config)
      project = Typingpool::Project.new(project_default[:title], config)
      vcr_names = ['tp_assign_4', 'tp_assign_5']
      copy_tp_assign_fixtures(dir, vcr_names[0], good_config_path)
      csv = project.local.file('data', 'assignment.csv').as(:csv)
      csv.each!{|a| a['audio_uploaded'] = 'yes'}
      bad_config_path = write_s3_config_with_bad_password(dir)
      get_assignment_urls = lambda{|assignments| assignments.map{|assignment| assignment['assignment_url'] }.select{|url| url } }
      assert_empty(get_assignment_urls.call(csv))
      begin
        exception = assert_raises(Typingpool::Error::Shell) do
          tp_assign_with_vcr(dir, vcr_names[0], bad_config_path)
        end #assert_raises...
        assert_match(/s3 operation fail/i, exception.message)
        sandbox_csv = project.local.file('data', 'sandbox-assignment.csv').as(:csv)
        refute_empty(get_assignment_urls.call(sandbox_csv))
        if (Typingpool::Test.record || Typingpool::Test.live)
          get_assignment_urls.call(sandbox_csv).each{|url| refute(Typingpool::Utility.working_url? url) }
        end
        assert_all_assets_have_upload_status(sandbox_csv, 'assignment', 'maybe')
        tp_assign_with_vcr(dir, vcr_names[1], good_config_path)
        if (Typingpool::Test.record || Typingpool::Test.live)
          get_assignment_urls.call(sandbox_csv).each{|url| assert(working_url_eventually? url) }
        end
        assert_all_assets_have_upload_status(sandbox_csv, 'assignment', 'yes')
      ensure
        tp_finish(dir, good_config_path) if (Typingpool::Test.record || Typingpool::Test.live)
      end #begin
    end #with_temp_readymade_project do...
  end

  def test_abort_on_config_mismatch
    skip_if_no_s3_credentials('tp-assign abort on config mismatch test')
    with_temp_readymade_project do |dir|
      config = reconfigure_for_s3(Typingpool::Config.file(config_path(dir)))
      good_config_path = write_config(dir, config, '.config_s3_good')
      reconfigure_project(Typingpool::Project.new(project_default[:title], config))
      assert(config.amazon.bucket)
      new_bucket = 'configmismatch-test'
      refute_equal(new_bucket, config.amazon.bucket)
      config.amazon.bucket = new_bucket
      bad_config_path = write_config(dir, config, '.config_s3_bad')
      success = false
      begin
        exception = assert_raises(Typingpool::Error::Shell) do
          tp_assign(dir, bad_config_path)
        end #assert_raises...
        assert_match(/\burls don't look right\b/i, exception.message)
        success = true
      ensure
        tp_finish(dir, good_config_path) unless success
      end #begin
    end #with_temp_readymade_project do...
  end

  def test_displays_and_uses_correct_reward_default
    with_temp_readymade_project do |dir| 
      project = Typingpool::Project.new(project_default[:title], Typingpool::Config.file(config_path(dir)))
      config = Typingpool::Config.file(config_path(dir))
      config.assign.reward = '0.06'
      write_config(dir, config)
      vcr_names = ['tp_assign_6', 'tp_assign_7']
      copy_tp_assign_fixtures(dir, vcr_names[0])
      config = Typingpool::Config.file(config_path(dir))
      assert_equal('0.06', config.assign.reward.to_s)
      Typingpool::Amazon.setup(:sandbox => true, :config => config)
      with_vcr(vcr_names[1], config, {
                 :preserve_exact_body_bytes => true,
                 :match_requests_on => [:method, vcr_core_host_matcher]
               }) do
        begin
          _, err = tp_assign_with_vcr(dir, vcr_names[0])
          assert_match(/would cost \$((0\.44)||(0\.51))\./, err)
          refute_empty(results = Typingpool::Amazon::HIT.all_for_project(project.local.id))
          assert_equal('0.06', results.first.at_amazon.reward_amount.to_s)
        ensure
          tp_finish(dir) if (Typingpool::Test.record || Typingpool::Test.live)
        end #begin
      end #with_temp_readymade_project do...
    end #with_vcr...
  end
end #TestTpAssign
