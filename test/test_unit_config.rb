#!/usr/bin/env ruby

$:.unshift File.join(File.dirname(File.dirname($0)), 'lib')

require 'typingpool'
require 'typingpool/test'

class TestConfig < Typingpool::Test

  def test_config_regular
    assert(config = Typingpool::Config.file(File.join(fixtures_dir, 'config-1')))
    assert_equal('~/Documents/Transcripts/', config['transcripts'])
    assert_match(config.transcripts, /Transcripts$/)
    refute_match(config.transcripts, /~/)
    %w(key secret).each do |param| 
      regex = /test101010/
      assert_match(config.amazon.send(param), regex) 
      assert_match(config.amazon[param], regex)
      assert_match(config.amazon.to_hash[param], regex)
    end
    assert_equal(0.75, config.assign.reward.to_f)
    assert_equal(3*60*60, config.assign.deadline.to_i)
    assert_equal('3h', config.assign['deadline'])
    assert_equal(60*60*24*2, config.assign.lifetime.to_i)
    assert_equal('2d', config.assign['lifetime'])
    assert_equal(3, config.assign.keywords.count)
    assert_kind_of(Typingpool::Config::Root::Assign::Qualification, config.assign.qualify.first)
    assert_equal(:approval_rate, config.assign.qualify.first.to_arg[0])
    assert_equal(:gte, config.assign.qualify.first.to_arg[1].keys.first)
    assert_equal('95', config.assign.qualify.first.to_arg[1].values.first.to_s)
  end

  def test_config_sftp
    assert(config = Typingpool::Config.file(File.join(fixtures_dir, 'config-2')))
    assert_equal('ryan', config.sftp.user)
    assert_equal('public_html/transfer/', config.sftp['path'])
    assert_equal('public_html/transfer', config.sftp.path)
    assert_equal('http://example.com/mturk/', config.sftp['url'])
    assert_equal('http://example.com/mturk', config.sftp.url)
  end

  def test_config_screwy
    assert(config = Typingpool::Config.file(File.join(fixtures_dir, 'config-2')))
    exception = assert_raises(Typingpool::Error::Argument) do 
      config.assign.qualify
    end
    assert_match(exception.message, /Unknown qualification type/i)
    config.assign['qualify'] = [config.assign['qualify'].pop]
    exception = assert_raises(Typingpool::Error::Argument) do 
      config.assign.qualify
    end
    assert_match(exception.message, /Unknown comparator/i)
    assert_equal('3z', config.assign['deadline'])
    exception = assert_raises(Typingpool::Error::Argument::Format) do
      config.assign.deadline
    end
    assert_match(exception.message, /can't convert/i)
  end
end #TestConfig
