#!/usr/bin/env ruby

$:.unshift File.join(File.dirname(File.dirname($0)), 'lib')

require 'typingpool'
require 'typingpool/test'

class TestTpAssign < Typingpool::Test::Script
  #TODO: test that qualifications are sent (will need heroic effort
  #(or at least some xml parsing) since rturk doesn't provide an
  #easy way to look at HIT qualifications)
  def test_abort_with_no_input
    assert_raise(Typingpool::Error::Shell){call_tp_assign}
  end

  def test_abort_with_no_template
    exception = assert_raise(Typingpool::Error::Shell){call_tp_assign(project_default[:title])}
    assert_match(exception.message, /Missing\b[^\n\r\f]*\btemplate/)
  end

  def test_abort_with_bad_timespec
    exception = assert_raise(Typingpool::Error::Shell) do
      call_tp_assign(project_default[:title], assign_default[:template], '--lifetime', '4u')
    end
    assert_match(exception.message, /can't convert/i)
  end

  def test_abort_with_bad_qualification
    exception = assert_raise(Typingpool::Error::Shell) do
      call_tp_assign(project_default[:title], assign_default[:template], '--qualify', 'approval_rate &= 8')
    end
    assert_match(exception.message, /sense of --qualify/i)
    assert_match(exception.message, /unknown comparator/i)
    exception = assert_raise(Typingpool::Error::Shell) do
      call_tp_assign(project_default[:title], assign_default[:template], '--qualify', 'fake_rate > 8', '--sandbox')
    end
    assert_match(exception.message, /sense of --qualify/i)
    assert_match(exception.message, /unknown\b[^\n\r\f]*\btype/i)
  end

  def test_abort_with_bad_reward
    exception = assert_raise(Typingpool::Error::Shell) do
      call_tp_assign(project_default[:title], assign_default[:template], '--reward', 'foo')
    end
    assert_match(exception.message, /sense of --reward/i)
  end

  def test_tp_assign
    skip_if_no_amazon_credentials('tp-assign integration test')
    skip_if_no_upload_credentials('tp-assign integration test')
    in_temp_tp_dir do |dir|
      tp_make(dir)
      begin
        assigning_started = Time.now
        tp_assign(dir)
        assign_time = Time.now - assigning_started
        config = config_from_dir(dir)
        project = temp_tp_dir_project(dir)
        setup_amazon(dir)
        results = nil
        refute_empty(results = Typingpool::Amazon::HIT.all_for_project(project.local.id))
        assert_equal(project.local.subdir('audio','chunks').to_a.size, results.size)
        assert_equal(Typingpool::Utility.timespec_to_seconds(assign_default[:deadline]), results[0].full.assignments_duration.to_i)
        #These numbers will be apart due to clock differences and
        #timing vagaries of the assignment.
        assert_in_delta((assigning_started + assign_time + Typingpool::Utility.timespec_to_seconds(assign_default[:lifetime])).to_f, results[0].full.expires_at.to_f, 60)
        keywords = results[0].at_amazon.keywords
        assign_default[:keyword].each{|keyword| assert_includes(keywords, keyword)}
        sandbox_csv = project.local.file('data', 'sandbox-assignment.csv').as(:csv)
        refute_empty(assignment_urls = sandbox_csv.map{|assignment| assignment['assignment_url'] })
        assert(assignment_html = fetch_url(assignment_urls.first).body)
        assert_match(assignment_html, /\b20[\s-]+second\b/)
        assert_all_assets_have_upload_status(sandbox_csv, ['assignment'], 'yes')
      ensure
        tp_finish(dir)
      end #begin
      assert_empty(Typingpool::Amazon::HIT.all_for_project(project.local.id))
    end # in_temp_tp_dir
  end

   def test_uploads_audio_when_needed
     skip_if_no_amazon_credentials('tp-assign unuploaded audio integration test')
     skip_if_no_s3_credentials('tp-assign unuploaded audio integration test')
     in_temp_tp_dir do |dir|
       good_config_path = setup_s3_config(dir)
       bad_config_path = setup_s3_config_with_bad_password(dir)
       assert_raises(Typingpool::Error::Shell) do
         tp_make(dir, bad_config_path, 'mp3')
       end
       project_dir = temp_tp_dir_project_dir(dir)
       assert(File.exists? project_dir)
       assert(File.directory? project_dir)
       assert(project = temp_tp_dir_project(dir, Typingpool::Config.file(bad_config_path)))
       csv = project.local.file('data', 'assignment.csv').as(:csv)
       assert_empty(csv.select{|assignment| working_url? assignment['audio_url']})
       assert_all_assets_have_upload_status(csv, ['audio'], 'maybe')
       begin
         tp_assign(dir, good_config_path)
         sandbox_csv = project.local.file('data', 'sandbox-assignment.csv').as(:csv)
         assert_equal(csv.count, sandbox_csv.count)
         assert_equal(sandbox_csv.count, sandbox_csv.select{|assignment| working_url? assignment['audio_url'] }.count)
         assert_all_assets_have_upload_status(sandbox_csv, ['audio'], 'yes')
#        TODO (bugfix): assert_all_assets_have_upload_status(csv, ['audio'], 'yes')
       ensure
         tp_finish(dir, good_config_path)
       end #begin
     end # in_temp_tp_dir do...
   end

def test_fixing_failed_assignment_html_upload
  skip_if_no_amazon_credentials('tp-assign failed assignment upload integration test')
  skip_if_no_s3_credentials('tp-assign failed assignment upload integration test')
  in_temp_tp_dir do |dir|
    good_config_path = setup_s3_config(dir)
    bad_config_path = setup_s3_config_with_bad_password(dir)
    tp_make(dir, good_config_path, 'mp3')
    begin
      assert(project = temp_tp_dir_project(dir, Typingpool::Config.file(good_config_path)))
      assert(project.local)
      get_assignment_urls = lambda{|csv| csv.map{|assignment| assignment['assignment_url'] }.select{|url| url } }
      assert_empty(get_assignment_urls.call(project.local.file('data', 'assignment.csv').as(:csv)))
      exception = assert_raises(Typingpool::Error::Shell) do
        tp_assign(dir, bad_config_path)
      end #assert_raises...
      assert_match(exception.message, /s3 operation fail/i)
      sandbox_csv = project.local.file('data', 'sandbox-assignment.csv').as(:csv)
      refute_empty(get_assignment_urls.call(sandbox_csv))
      check_assignment_urls = lambda{ get_assignment_urls.call(sandbox_csv).map{|url| Typingpool::Utility.working_url? url } }
      check_assignment_urls.call.each{|checked_out| refute(checked_out) }
      assert_all_assets_have_upload_status(sandbox_csv, ['assignment'], 'maybe')
      tp_assign(dir, good_config_path)
      check_assignment_urls.call.each{|checked_out| assert(checked_out) }
      assert_all_assets_have_upload_status(sandbox_csv, ['assignment'], 'yes')
    ensure
      tp_finish(dir, good_config_path)
    end #begin
  end #in_temp_tp_dir do...
end

def test_abort_on_config_mismatch
  skip_if_no_s3_credentials('tp-assign abort on config mismatch test')
  in_temp_tp_dir do |dir|
    config = config_from_dir(dir)
    good_config_path = setup_s3_config(dir, config, '.config_s3_good')
    tp_make(dir, good_config_path)
    begin
      tp_finish_outside_sandbox(dir, good_config_path)
      assert(config.amazon.bucket)
      new_bucket = 'configmismatch-test'
      refute_equal(new_bucket, config.amazon.bucket)
      config.amazon.bucket = new_bucket
      bad_config_path = setup_s3_config(dir, config, '.config_s3_bad')
      exception = assert_raises(Typingpool::Error::Shell) do
        tp_assign(dir, bad_config_path)
      end #assert_raises...
      assert_match(exception.message, /\burls don't look right\b/i)
    ensure
      tp_finish(dir, good_config_path)
    end #begin
  end #in_temp_tp_dir do...
end

end #TestTpAssign
