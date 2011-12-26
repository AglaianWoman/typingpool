#!/usr/bin/env ruby

require 'optparse'
require 'erb'
require 'audibleturk'

options = nil
config = nil
configs = [Audibleturk::Config.file]

#We need to incorporate command line options immediately into the
#config object, since it checks incoming values for us (see rescue
#clauses).
#
#BUT the user can specify an alternate config file at an arbitrary
#point in the command line options string. So in those cases we loop
#and do it all again. (Actually we loop twice in all cases, because we
#need to do a destructive parse the second time around, and there's no
#way of knowing in advance if we can do a destructive parse the first
#time.)
#
#This solution is DRY and simple. The alternatives tend to be complex
#or repetitive.

2.times do |i|
  config = configs.last
  options = {}
  yet = {}
  option_parser = OptionParser.new do |opts|
    options[:banner] = opts.banner = "USAGE: #{File.basename($PROGRAM_NAME)} PROJECT TEMPLATE [--reward 0.75]\n  [--keyword transcription --keyword mp3...] [--deadline 3h] [--lifetime 2d]\n  [--approval 1d] [--qualify 'approval_rate >= 95' --qualify 'hits_approved > 10'...]\n  [--sandbox] [--copies 2] [--currency USD] [--config PATH]\n"
    opts.on('--project=PROJECT', "Required. Path or name within $config:local.", "  Also accepted via STDIN") do |project|
      options[:project] = project
    end
    opts.on('--template=TEMPLATE', "Required. Path or relative path in", "  $config:app/templates/assignment") do |template|
      options[:template] = template
    end
    opts.on('--reward=DOLLARS', "Default: $config:assignments:reward.", "  Per chunk. Format N.NN") do |reward|
      reward.match(/(\d+(\.\d+)?)|(\d*\.\d+)/) or abort "Bad --reward format '#{reward}'"
      config.assignments.reward = reward
    end
    opts.on('--currency=TYPE', "Default: $config:assignments:currency") do |currency|
      config.assignments.currency = currency
    end
    opts.on('--keyword=WORD', "Default: $config:assignments:keywords.", "  Repeatable") do |keyword|
      unless yet[:keyword]
        yet[:keyword] = true
        #We ignore keywords from the conf file if the user specified any.
        config.assignments.keywords = []
      end
      config.assignments.keywords.push(keyword)
    end
    Hash[
         'deadline' => 'Worker time to transcribe',
         'lifetime' => 'Assignment time to expire',
         'approval' => 'Submission time to auto approve'
        ].each do |param, meaning|
      opts.on("--#{param}=TIMESPEC", "Default: $config:assignments:#{param}.", "  #{meaning}.", "  N[.N]y|M(onths)|d|h|m(inutes)|s") do |timespec|
        begin
          config.assignments.send("#{param}=", timespec)
        rescue Audibleturk::Error::Argument => e
          abort "Bad --#{param} '#{timespec}': #{e}"
        end
      end
    end
    opts.on('--qualify=QUALIFICATION', "Default: $config:assignments:qualify.","  Repeatable.", "  An RTurk::Qualifications::TYPES +", "  >|<|==|!=|true|exists|>=|<=", "  [+ INT]") do |qualification|
      unless yet[:qualify]
        yet[:qualify] = true
        #We ignore qualifications from the conf file if the user specified any.
        config.assignments.qualify = []
      end
      begin
        config.assignments.add_qualification(qualification)
      rescue Audibleturk::Error::Argument => e
        abort "Bad --qualify '#{qualification}': #{e}"
      end
    end
    opts.on('--sandbox', "Test in Mechanical Turk's sandbox") do
      options[:sandbox] = true
    end
    opts.on('--copies=INT', "Default: $config:assignments:copies.", "  How many times to assign each chunk.", "  Currently, related scripts only handle 1 copy") do |copies|
      copies.match(/^\d+$/) or abort "--copies must be an integer"
      config.assignments.copies = copies
    end
    opts.on('--config=PATH', 'Default: ~/.audibleturk') do |path|
      path = File.expand_path(path)
      File.exists?(path) && File.file?(path) or abort "No such file #{path}"
      new_config = Audibleturk::Config.file(path)
      configs.push(new_config) unless new_config.path == config.path
    end
    opts.on('--help', 'Display this screen') do
      $stderr.puts opts
      exit
    end
  end
  if i == 0
    option_parser.parse(ARGV)
  else
    option_parser.parse!
  end
end

options[:banner] += "`#{File.basename($PROGRAM_NAME)} --help` for more information.\n"
options[:banner] = "\n#{options[:banner]}"

positional = %w(project template)
#Anything waiting on STDIN?
if STDIN.fcntl(Fcntl::F_GETFL, 0) == 0
  project = $stdin.gets.chomp
  if project
    abort "Duplicate project values (STDIN and --project)" if options[:project]
    options[:project] = project
    positional.shift
  end
end
positional.each do |name|
  arg = ARGV.shift
  abort "Duplicate values for #{name}" if (not(arg.to_s.empty?)) && (not(options[name.to_sym].to_s.empty?))
  options[name.to_sym] = arg if options[name.to_sym].to_s.empty?
  abort "Missing required arg #{name}#{options[:banner]}" if options[name.to_sym].to_s.empty?
end
abort "Unexpected argument(s): #{ARGV.join(';')}" if not(ARGV.empty?)

if not(File.exists?(options[:project]))
  abort "Required param 'local' missing from config file '#{config.path}'" if config.local.to_s.empty?
  options[:project] = "#{config.local}/#{options[:project]}"
end
if not(File.exists?(options[:template]))
  abort "Required param 'app' missing from config file '#{config.app}'" if config.app.to_s.empty?
  options[:template] = "#{config.app}/templates/assignment/#{options[:template]}"
  options[:template] += '.html.erb' if not(File.file?(options[:template]))
end
%w(project template).each do |arg|
  abort "No #{arg} at #{options[arg.to_sym]}" if not(File.exists?(options[arg.to_sym]))
end
abort "Template '#{options[:template]}' is not a file" if not(File.file?(options[:template]))
abort "Project '#{options[:project]}' is not a directory" if not(File.directory?(options[:project]))

project = Audibleturk::Project.new(File.basename(options[:project]))
project_local = project.local(File.dirname(options[:project]))

abort "Not a project directory at '#{options[:project]}'" if not(project_local)
abort "No data in assignment CSV" if project_local.csv('assignment').empty?
abort "No AWS key+secret in config" if not(config.param['aws'] && config.param['aws']['key'] && config.param['aws']['secret'])

Audibleturk::Amazon.setup(:sandbox => options[:sandbox], :key => config.param['aws']['key'], :secret => config.param['aws']['secret'])

template = IO.read(options[:template])
results = []
$stderr.puts 'Assigning...'
assignments = project_local.csv('assignment')
assignments.each do |hit|
  xhtmlf = ERB.new(template, nil, '<>').result(Audibleturk::ErbBinding.new(hit).send(:get_binding))
  assignment = Audibleturk::Amazon::Assignment.new(xhtmlf, config.assignments)
  begin
    results.push(assignment.assign)
  rescue  RTurk::RTurkError => e
    $stderr.puts "Mechanical Turk error: #{e}"
    unless results.empty?
      $stderr.puts "Rolling back assignments..."
      results.each{|hit| hit.disable!}
    end
    abort
  end
  $stderr.puts "Assigned #{results.size} / #{assignments.size}"
end