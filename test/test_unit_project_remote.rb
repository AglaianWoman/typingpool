#!/usr/bin/env ruby

$:.unshift File.join(File.dirname(File.dirname($0)), 'lib')

require 'typingpool'
require 'typingpool/test'
require 'stringio'

class TestProjectRemote < Typingpool::Test
  def test_project_remote_from_config
    assert(remote = Typingpool::Project::Remote.from_config(project_default[:title], dummy_config(1)))
    assert_instance_of(Typingpool::Project::Remote::S3, remote)
    assert(remote = Typingpool::Project::Remote.from_config(project_default[:title], dummy_config(2)))
    assert_instance_of(Typingpool::Project::Remote::SFTP, remote)
    config = dummy_config(2)
    config.to_hash.delete('sftp')
    assert_raises(Typingpool::Error) do
      Typingpool::Project::Remote.from_config(project_default[:title], config)
    end #assert_raises
  end

  def test_project_remote_s3_base
    config = dummy_config(1)
    assert(remote = Typingpool::Project::Remote::S3.new(project_default[:title], config.amazon))
    %w(key secret bucket).each do |param|
      refute_nil(remote.send(param.to_sym))
      assert_equal(config.amazon.send(param.to_sym), remote.send(param.to_sym))
    end #%w().each do...
    assert_nil(config.amazon.url)
    assert_includes(remote.url, config.amazon.bucket)
    custom_url = 'http://tp.example.com/tp-test/1/2/3'
    config.amazon.url = custom_url
    assert(remote = Typingpool::Project::Remote::S3.new(project_default[:title], config.amazon))
    refute_nil(remote.url)
    refute_includes(remote.url, config.amazon.bucket)
    assert_includes(remote.url, custom_url)
    assert_equal('tp.example.com', remote.host)
    assert_equal('/tp-test/1/2/3', remote.path)
  end

  def test_project_remote_s3_networked
    assert(config = self.config)
    skip_if_no_s3_credentials('Project::Remote::S3 upload and delete tests', config)
    config.to_hash.delete('sftp')
    assert(project = Typingpool::Project.new(project_default[:title], config))
    assert_instance_of(Typingpool::Project::Remote::S3, remote = project.remote)
    standard_put_remove_tests(remote)
  end

  def test_project_remote_sftp_base
    config = dummy_config(2)
    assert(remote = Typingpool::Project::Remote::SFTP.new(project_default[:title], config.sftp))
    %w(host path user url).each do |param|
      refute_nil(remote.send(param.to_sym))
      assert_equal(config.sftp.send(param.to_sym), remote.send(param.to_sym))
    end #%w().each do...
    assert_equal('example.com', remote.host)
    assert_equal('public_html/transfer', remote.path)
  end

  def test_project_remote_sftp_networked
    assert(config = self.config)
    if not(config.sftp && config.sftp.user && config.sftp.host && config.sftp.url)
      skip_with_message('Missing or incomplete SFTP credentials', 'Project::Remote::SFTP upload and delete tests')
    end
    assert(project = Typingpool::Project.new(project_default[:title], config))
    assert_instance_of(Typingpool::Project::Remote::SFTP, remote = project.remote)
    standard_put_remove_tests(remote)
  end

  def standard_put_remove_tests(remote)
    basenames = ['amazon-question-html.html', 'amazon-question-url.txt']
    local_files = basenames.map{|basename| File.join(fixtures_dir, basename) }
    local_files.each{|path| assert(File.exists? path) }
    strings = local_files.map{|path| File.read(path) }
    strings.each{|string| refute_empty(string) }

    #with default basenames
    put_remove_test(
                    :remote => remote, 
                    :streams => local_files.map{|path| File.new(path) },
                    :test_with => lambda{|urls| urls.each_with_index{|url, i| assert_includes(url, basenames[i]) } }
                    )

    #now with different basenames
    remote_basenames = basenames.map{|name| [File.basename(name, '.*'), pseudo_random_chars, File.extname(name)].join }
    base_args = {
      :remote => remote,
      :as => remote_basenames,
      :test_with => lambda{|urls| urls.each_with_index{|url, i| assert_includes(url, remote_basenames[i]) }}
    }

    put_remove_test(
                    base_args.merge(
                                    :streams => local_files.map{|path| File.new(path) },
                                    )
                    )

    #now using remove_urls for removal
    put_remove_test(
                    base_args.merge(
                                    :streams => local_files.map{|path| File.new(path) },
                                    :remove_with => lambda{|urls|  base_args[:remote].remove_urls(urls) }
                                    )
                    )

    #now with stringio streams
    put_remove_test(
                    base_args.merge( 
                                    :streams => strings.map{|string| StringIO.new(string) },
                                    )
                    )


  end

  #Uploads and then deletes streams to a remote server, running some
  #basic tests along the way, along with some optional lambdas.
  # ==== Params
  # args[:remote]      Required. A Project::Remote instance to use for
  #                    putting and removing.  
  # args[:streams]     Required. An enumerable collection of IO streams to
  #                    put and remove.
  # args[:as]          Optional. An array of basenames to use to name the
  #                    streams remotely. Default is to call
  #                    Project::Remote#put with no 'as' param.
  # args[:test_with]   Optional. Lambda to call after putting the
  #                    streams and after running the standard tests.
  # args[:remove_with] Optional. Lambda to call to remove the remote
  #                    files. Default lambda calls
  #                    args[:remote].remove(args[:as])
  # ==== Returns
  #URLs of the former remote files (non functioning/404)
  def put_remove_test(args)
    args[:remote] or raise Error::Argument, "Must supply a Project::Remote instance as :remote"
    args[:streams] or raise Error::Argument, "Must supply an array of IO streams as :streams"
    args[:remove_with] ||= lambda do |urls| 
      args[:remote].remove(urls.map{|url| Typingpool::Utility.url_basename(url) })
    end #lambda do...
    put_args = [args[:streams]]
    put_args.push(args[:as]) if args[:as]
    assert(urls = args[:remote].put(*put_args))
    begin
      assert_equal(args[:streams].count, urls.count)
      urls.each{|url| assert(working_url?(url)) }
      args[:test_with].call(urls) if args[:test_with]
    ensure
      args[:remove_with].call(urls)
    end #begin
    urls.each{|url| refute(working_url?(url)) }
    urls
  end

  #Copy-pasted from Project::Remote so we don't have to make that a public method
  def pseudo_random_chars(length=6)
    (0...length).map{(65 + rand(25)).chr}.join
  end

end #TestProjectRemote