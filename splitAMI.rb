#!/usr/bin/env ruby
# creates an AMI that spans multiple EBS snapshots, based on an input AMI
# Usage:
#    splitAMI.rb [SOURCE_AMI] [PATH]:[SIZE]:[MOUNT_OPTIONS] [[PATH]:[SIZE]...]
require 'aws-sdk'
require 'aws-sdk-resources'
require 'fileutils'
require 'logger'
require 'open-uri'
require 'time'

################################
# STAGE 0 - CONFIGURATION
ROOT_DEVICE_NAME   = '/dev/sda1'
WORKDIR            = '/newami'
REMOVE_TAGS        = ['Name', 'Description', 'CreatedAt', 'CreatedFrom']
TIMESTAMP          = Time.now.strftime("%Y/%m/%d at %H:%M:%S")
src_id, *fs_params = ARGV
log = Logger.new(STDOUT)
log.formatter = proc do |severity, datetime, progname, msg|
   "#{severity}: #{msg}\n"
end

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
METADATA_URL   = 'http://169.254.169.254/latest/meta-data/'
AZ             = open("#{METADATA_URL}/placement/availability-zone"){|io| io.read}
REGION         = AZ.chop
client         = Aws::EC2::Client.new(region: REGION)
my_instance_id = open("#{METADATA_URL}/instance-id"){|io| io.read}
Aws.config.update(region: REGION)

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
base_tags = src_ami.tags.delete_if {|t| REMOVE_TAGS.include? t.key} <<
  Aws::EC2::Types::Tag.new(key: "CreatedAt", value: TIMESTAMP) <<
  Aws::EC2::Types::Tag.new(key: "CreatedFrom", value: src_id)

# find the original root disk's snapshot ID
root_mapping = src_mappings.find{|m| m.device_name == ROOT_DEVICE_NAME}
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

# create a new volume from the original root disk's snapshot ID
log.info "Creating a new root volume from snapshot ID #{root_snapshot}..."
root_volume_id = client.create_volume({
  availability_zone: AZ,
  size: root_mapping.ebs.volume_size,
  volume_type: root_mapping.ebs.volume_type,
  snapshot_id: root_snapshot,
}).volume_id
log.info "Waiting until root volume (#{root_volume_id}) is available..."
client.wait_until(:volume_available, volume_ids: [root_volume_id])

# attach the volume and mount it at WORKDIR/root
root_volume_path = "#{WORKDIR}/root"
root_volume_device = "#{local_device_map['root']}1"
log.info "Attaching root volume at #{local_device_map['root']}..."
FileUtils.mkdir_p(root_volume_path)
resp = client.attach_volume({
  device: local_device_map['root'],
  instance_id: my_instance_id,
  volume_id: root_volume_id,
})
client.wait_until(:volume_in_use, volume_ids: [root_volume_id])
sleep 30 # volume is still not attached sometimes?
log.info "Mounting root device #{root_volume_device} at #{root_volume_path}..."
`mount #{root_volume_device} #{root_volume_path}`


################################
# STAGE 2 - Create a new EBS Snapshot for each of the fs_params
mappings = src_mappings.map{|m| m.to_h} # track the created Device Mappings
snapshot_ids = []                       # also track created snapshot IDs

# iterate over each desired filesystem parameters,
# It's important to handle subdirectories before parent directories, so fs_params
# must be lexically sorted by the path, and then reversed
fs_params.sort{|a,b| a.split(':')[0] <=> b.split(':')[0]}.reverse.each do |fs_param|
  path, size, opts = fs_param.split(':')

  # create a new EBS data volume and wait until it's ready
  log.info "Creating a new #{size}GB data volume for #{path}..."
  data_volume_id = client.create_volume({
    availability_zone: AZ,
    size: size,
    volume_type: 'gp2',
  }).volume_id
  log.info "Waiting until volume for #{path} (#{data_volume_id}) is available..."
  client.wait_until(:volume_available, volume_ids: [data_volume_id])

  # attach the data volume
  data_volume_device = local_device_map[fs_param]
  data_volume_path = "/newami/#{data_volume_device.split('/').last}"
  log.info "Attaching data volume for #{path} at #{data_volume_device}..."
  FileUtils.mkdir_p(data_volume_path)
  resp = client.attach_volume({
    device: data_volume_device,
    instance_id: my_instance_id,
    volume_id: data_volume_id,
  })
  client.wait_until(:volume_in_use, volume_ids: [data_volume_id])
  sleep 30 # volume is still not attached sometimes?

  log.info "Creating filesystem for #{path} on #{data_volume_device}..."
  `mkfs -t ext4 #{data_volume_device}`
  log.info "Mounting data volume for #{path} at #{data_volume_path}..."
  `mount #{data_volume_device} #{data_volume_path}`

  # move the data from /newami/root/[PATH] to /newami/[PATH]
  src_dir = root_volume_path + path
  FileUtils.mkdir_p src_dir   # create source directory as needed
  log.info "Copying data from #{src_dir} -> #{data_volume_path}..."
  `tar -C #{src_dir} -cf - . | tar -C #{data_volume_path} -xBf -`
  log.info "Deleting data from #{src_dir}..."
  `rm -rf #{src_dir}/* #{src_dir}/.* >/dev/null 2>&1`

  log.info "Writing fstab entry for #{path} into #{root_volume_path}/etc/fstab"
  device = "xvd#{final_device_map[fs_param]}"
  File.open("#{root_volume_path}/etc/fstab", 'a') do |fstab|
    fstab.write "/dev/#{device}\t#{path}\text4\t#{opts}\t0\t0\n"
  end

  # unmount, detach, snapshot, and delete the volume
  log.info "Unmounting data volume for #{path} at #{data_volume_path}..."
  `umount #{data_volume_path}`
  log.info "Detaching data volume for #{path} (#{data_volume_device})..."
  client.detach_volume(volume_id: data_volume_id)
  client.wait_until(:volume_available, volume_ids: [data_volume_id])
  log.info "Snapshotting data volume for #{path} #{data_volume_id}..."
  snapshot_id = client.create_snapshot(
    description: "#{src_ami.name} /dev/#{device}",
    volume_id: data_volume_id,
  ).snapshot_id
  snapshot_ids << snapshot_id
  log.info "Deleting data volume for #{path} #{data_volume_id}..."
  client.delete_volume(volume_id: data_volume_id)

  # create the AWS Block Device Mapping for this volume
  mappings <<  {
  device_name: device,
    virtual_name: "ebs",
    ebs: {
      snapshot_id: snapshot_id,
      delete_on_termination: true,
      volume_type: 'gp2',
    }
  }
end # Done with fs_params


################################
# STAGE 3 - Snapshot and delete the root volume
log.info "Unmounting root volume from #{root_volume_path}..."
`umount #{root_volume_path} && rm -rf #{WORKDIR}`  # clean up
log.info "Detaching root volume #{root_volume_id}..."
client.detach_volume(volume_id: root_volume_id)
client.wait_until(:volume_available, volume_ids: [root_volume_id])
log.info "Snapshotting root volume #{root_volume_id}..."
root_snapshot_id = client.create_snapshot({
  description: "#{src_ami.name} root disk",
  volume_id: root_volume_id,
}).snapshot_id
snapshot_ids << root_snapshot_id
log.info "Deleting root volume #{root_volume_id}..."
client.delete_volume(volume_id: root_volume_id)

# create the final AWS Block Device Mappings
mappings.each do |mapping|
  if mapping[:ebs]
    mapping[:ebs].delete(:encrypted)
    if mapping[:device_name] == ROOT_DEVICE_NAME
      mapping[:ebs][:snapshot_id] = root_snapshot_id
    end
  end
end
log.debug "Final block device mappings: #{mappings}"
log.info "Waiting for snapshots to complete..."
client.wait_until(:snapshot_completed, snapshot_ids: snapshot_ids)


################################
# STAGE 4 - Register the new AMI and tag created resources
# first, make all snapshots public
snapshot_ids.each do |snap_id|
  client.modify_snapshot_attribute(
    attribute: "createVolumePermission",
    group_names: ["all"],
    operation_type: "add",
    snapshot_id: snap_id)
end

ILLEGAL_CHARS = /[^a-zA-z0-9().,-\/_ ]+/ # characters not permitted in AMI names
ami_name = "#{src_ami.name} split on #{TIMESTAMP}".gsub(ILLEGAL_CHARS,'-')
log.info "Registering new AMI Image #{ami_name}..."
new_ami_id = client.register_image({
  name: ami_name,
  description: "#{src_ami.description} - split",
  architecture: src_ami.architecture,
  kernel_id: src_ami.kernel_id,
  ramdisk_id: src_ami.ramdisk_id,
  root_device_name: root_mapping.device_name,
  block_device_mappings: mappings,
  virtualization_type: src_ami.virtualization_type,
  sriov_net_support: src_ami.sriov_net_support,
  ena_support: src_ami.ena_support,
}).image_id
log.info "Waiting for AMI #{new_ami_id} to become ready..."
client.wait_until(:image_available, image_ids: [new_ami_id])

log.info "Tagging AMI #{new_ami_id}..."
client.create_tags(
  resources: [new_ami_id],
  tags:  base_tags <<
    Aws::EC2::Types::Tag.new(key: "Name", value: ami_name) <<
    Aws::EC2::Types::Tag.new(key: "Description", value:
      "#{src_ami.description} split on #{TIMESTAMP}"))

# tag all created snapshots
mappings.each do |mapping|
  if mapping[:ebs] && snapshot_ids.include?(mapping[:ebs][:snapshot_id])
    log.info "Tagging snapshot #{mapping[:ebs][:snapshot_id]}..."
    client.create_tags(
      resources: [mapping[:ebs][:snapshot_id]],
      tags:  base_tags <<
        Aws::EC2::Types::Tag.new(key: "Name", value:
          "#{new_ami_id} #{mapping[:device_name]}") <<
        Aws::EC2::Types::Tag.new(key: "Description", value:
          "Created by splitImage.rb (#{my_instance_id}) for #{new_ami_id}"))
  end
end

log.info "Making AMI #{new_ami_id} public..."
client.modify_image_attribute({
  image_id: new_ami_id,
  launch_permission: {add: [{group: "all"}]}})


################################
log.info "Done. Created AMI #{new_ami_id} => #{ami_name}"
