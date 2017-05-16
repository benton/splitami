#!/usr/bin/env ruby
# creates an AMI that spans multiple EBS snapshots, based on an input AMI
# Usage:
#    splitAMI.rb [SOURCE_AMI] [PATH]:[SIZE]:[MOUNT_OPTIONS] [[PATH]:[SIZE]...]
require 'aws-sdk'
require 'aws-sdk-resources'
require 'fileutils'
require 'logger'
require 'open-uri'

################################
# STAGE 0 - CONFIGURATION
log = Logger.new(STDOUT)
src_id, *fs_params = ARGV

# validate arguments
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

log.info "Detecting AWS Region from EC2 metadata service..."
METADATA_URL = 'http://169.254.169.254/latest/meta-data/'
AZ           = open("#{METADATA_URL}/placement/availability-zone"){|io| io.read}
REGION       = AZ.chop
Aws.config.update({region: REGION})
client         = Aws::EC2::Client.new
my_instance_id = open("#{METADATA_URL}/instance-id"){|io| io.read}

# assign an unused local unix device name to each of the fs_params
candidate_devices = ('b'...'z').to_a.map{|dev| "/dev/xvd#{dev}"}
available_devices = (candidate_devices - Dir["/dev/xvd*"]).sort
local_device_map = {'root' => available_devices.first}
i = 0 ; while i < fs_params.count do
  local_device_map[fs_params[i]] = available_devices[i+1]
  i += 1
end


################################
# STAGE 1 - Mount a new volume with the contents of the source AMI's root disk
src_ami = Aws::EC2::Image.new(src_id)
src_mappings = src_ami.block_device_mappings

# find the original root disk's snapshot ID
root_mapping = src_mappings.find{|m| m.device_name == '/dev/sda1'}
root_snapshot = root_mapping.ebs.snapshot_id

# assign an unused final unix device name to each of the fs_params
candidate_letters = ('b'...'z').to_a
used_letters = src_mappings.map{|m| m.device_name.gsub(/\d+\Z/,'')[-1, 1]}
available_letters = (candidate_letters - used_letters).sort
final_device_map = {}
i = 0 ; while i < fs_params.count do
  final_device_map[fs_params[i]] = available_letters[i+1]
  i += 1
end

# create a new EBS Volume from the original root disk's snapshot ID
log.info "Creating a new EBS Volume from snapshot ID #{root_snapshot}..."
root_volume_id = client.create_volume({
  availability_zone: AZ,
  size: root_mapping.ebs.volume_size,
  volume_type: root_mapping.ebs.volume_type,
  snapshot_id: root_snapshot,
}).volume_id
log.info "Waiting until AMI Root volume (#{root_volume_id}) is available..."
client.wait_until(:volume_available, volume_ids: [root_volume_id])

# attach the volume and mount it at /newami/root
root_volume_path = '/newami/root'
root_volume_device = "#{local_device_map['root']}1"
log.info "Attaching AMI Root volume (#{root_volume_id}) at #{root_volume_path}..."
FileUtils.mkdir_p(root_volume_path)
resp = client.attach_volume({
  device: root_volume_device,
  instance_id: my_instance_id,
  volume_id: root_volume_id,
})
client.wait_until(:volume_in_use, volume_ids: [root_volume_id])
sleep 30 # Volume is still not attached sometimes?
log.info "Mounting root device #{root_volume_device} at #{root_volume_path}..."
`mount #{root_volume_device} #{root_volume_path}`


################################
# STAGE 2 - Create a new EBS Snapshot for each of the fs_params
mappings = []  # track the created EBS Block Device Mappings
# iterate over each desired filesystem parameters, and for each...
fs_params.each do |fs_param|
  path, size, opts = fs_param.split(':')

  # create a new EBS data Volume and wait until it's ready
  log.info "Creating a #{size}GB EBS Volume for #{path}, for new AMI..."
  data_volume_id = client.create_volume({
    availability_zone: AZ,
    size: size,
    volume_type: 'gp2',
  }).volume_id
  log.info "Waiting until volume for #{path} (#{data_volume_id}) is available..."
  client.wait_until(:volume_available, volume_ids: [data_volume_id])

  # attach the data volume
  data_volume_device = local_device_map[fs_param]
  data_volume_path = "/newami/##{data_volume_device.split('/').last}"
  log.info "Attaching data volume for #{path} at #{data_volume_device}..."
  FileUtils.mkdir_p(data_volume_path)
  resp = client.attach_volume({
    device: data_volume_device,
    instance_id: my_instance_id,
    volume_id: data_volume_id,
  })
  client.wait_until(:volume_in_use, volume_ids: [data_volume_id])
  sleep 30 # Volume is still not attached sometimes?

  log.info "Creating filesystem for #{path} on #{data_volume_device}..."
  `mkfs -t ext4 #{data_volume_device}`
  log.info "Mounting data volume for #{path} at #{data_volume_path}..."
  `mount #{data_volume_device} #{data_volume_path}`

  # move the data from /newami/root/[PATH] to /newami/[PATH]
  src_dir = root_volume_path + path
  log.info "Copying data from #{src_dir} -> #{data_volume_path}..."
  `tar -C #{src_dir} -cf - . | tar -C #{data_volume_path} -xBf -`
  log.info "Deleting data from #{src_dir}..."
  `rm -rf #{src_dir}/* #{src_dir}/.*`

  log.info "Writing fstab entry for #{path} into #{root_volume_path}/etc/fstab"
  device = "xvd#{final_device_map[fs_param]}"
  File.open("#{root_volume_path}/etc/fstab", 'a') do |fstab|
    fstab.write "/dev/#{device}\t#{path}\text4\t#{opts}\t0\t0\n"
  end

  # unmount, detach, snapshot, and delete the EBS Volume
  log.info "Unmounting data volume for #{path} at #{data_volume_path}..."
  `umount #{data_volume_path}`
  log.info "Detaching data volume for #{path} (#{data_volume_device})..."
  client.detach_volume(volume_id: data_volume_id)
  client.wait_until(:volume_available, volume_ids: [data_volume_id])
  log.info "Snapshotting data volume for #{path} #{data_volume_id}..."
  snapshot_id = client.create_snapshot({
    description: "AMI Volume Snapshot for #{device}, mounted at #{path}",
    volume_id: data_volume_id,
  }).snapshot_id
  log.info "Deleting data volume for #{path} #{data_volume_id}..."
  client.delete_volume(volume_id: data_volume_id)

  # create the AWS Block Device Mapping for this volume
  mappings <<  {
    virtual_name: "ebs",
    device_name: device,
    ebs: {
      snapshot_id: snapshot_id,
      delete_on_termination: true,
      volume_type: 'gp2',
      encrypted: false,
    }
  }
end # Done with fs_params

log.info "  --> mappings: #{mappings}"


# STAGE 3 - Snapshot the /newami root disk and register the new AMI
# copy the original Tags
