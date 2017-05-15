#!/usr/bin/env ruby
# creates an AMI that spans multiple EBS snapshots, based on an input AMI
# Usage:
#    splitAMI.rb [SOURCE_AMI] [PATH]:[SIZE]:[MOUNT_OPTIONS] [[PATH]:[SIZE]...]
require 'aws-sdk'
require 'aws-sdk-resources'
require 'logger'
require 'open-uri'

# STEP 0 - CONFIGURATION
log = Logger.new(STDOUT)
src_id, *fs_params = ARGV # validate arguments
unless src_id =~ /\Aami-[0-9a-f]+\Z/
  abort "Initial argument (#{src_id}) must be an EC2 AMI ID in the current region"
end
abort "Filesystem parameters (PATH:SIZE:FS_OPTIONS) required" unless fs_params.count > 0
FS_PARAM_MATCH = %r{\A(/[^:]+):([0-9.]+):([^:]+)\Z}
fs_params.each do |fs_param|
  unless fs_param =~ FS_PARAM_MATCH
    abort "Filesystem parameters must match #{FS_PARAM_MATCH.to_s}"
  end
end
log.info "Source AMI = #{src_id}, Filesystem parameters = #{fs_params.join ' '}"

# STEP 1 - Read disk mappings for source AMI and mount its root disk contents
log.info "Detecting EC2 Region from metadata service URL..."
METADATA_URL='http://169.254.169.254/latest/meta-data/'
REGION = open("#{METADATA_URL}/placement/availability-zone"){|io| io.read}.chop
ENV['AWS_REGION'] = REGION
ec2 = Aws::EC2::Client.new(region: REGION)
src_ami = Aws::EC2::Image.new(src_id)
src_mappings = src_ami.block_device_mappings
log.info "mappings: #{src_mappings}"
