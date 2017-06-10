splitami - Splits an Amazon AMI across multiple EBS snapshots
================
----------------
Overview
----------------
This program divides the root volume of an Amazon Machine Image (AMI) into several different volumes, each of which contains a subdirectory of the original disk's filesystem. The program then registers a new AMI that specifies fresh EBS volumes at the original locations, with the original content. The objective is to ensure that certain directories that are "special" to the OS, like `/tmp` and `/var`, can reside on their own disk partitions, which is impractical to achieve once a system has already been booted.

As input, the program takes the original Machine Image ID (AMI ID) and a list of simple volume specifications, of the format `/PATH:SIZE:FSTAB_OPTIONS`. For example, the parameter `/tmp:20:nodev,nosuid` will ensure that the output AMI has a 20GB EBS volume mounted at `/tmp`, with the `nodev,nosuid` options listed in the `/etc/fstab` file.

The program will also create a new volume for a directory that does _not_ yet exist on the root volume (or is empty). In this case, the resulting AMI will just mount an empty, formatted volume of the desired size at that location. Thus, you can also use this software to add "data volumes" to an AMI. (Note, however, that all volumes created by the output AMI at instance boot time are flagged for deletion when the instance is terminated.)  

----------------
Installation
----------------
Though this software is written in Ruby, and its dependencies managed by Bundler, it can only run within EC2, because it needs access to the source AMI's root volume. Therefore, it's easiest to run the program through the [provided CloudFormation template][2], which works in all AWS Regions, and automatically cleans up after itself.

Nevertheless, if you want to run it on your own EC2 instance, just perform the usual installation process with Ruby v2.x (or later):

    gem install io-console bundler
    git clone https://github.com/benton/splitami.git
    cd splitami
    bundle install    

----------------
Usage
----------------
Use the [CloudFormation Console][3] to create a new Stack based on the [provided CloudFormation template][2]. Make sure you create your Stack in the same Region as your source AMI! Here are the inputs:

* `AppFilesystemParameters` - a space-separated list of volume specifications, of the format `/PATH:SIZE:FSTAB_OPTIONS`. For example, the parameter `/tmp:20:nodev,nosuid` will ensure that the output AMI has a 20GB EBS volume mounted at `/tmp`, with the `nodev,nosuid` options listed in the `/etc/fstab` file.

* `AppSourceAMI` - the ID of the original Amazon Machine Image, which must be EBS-backed.

* `InstanceBootKey` - the EC2 Boot Key, installed for user 'ec2-user'. This should be needed only for debugging.

* `InstanceType` - the EC2 instance type for the system that does the work; a `t2.micro` works fine.

* `LogRetention` - Number of days to retain a log of this run. The output is stored in [AWS Cloudwatch Logs][6], and a Console URL for the log is provided as a template Output.

* `Shutdown` - whether or not to delete this CloudFormation Stack when the program has completed. If set to `true`, all created Resources in AWS will be deleted on completion, except for the LogGroup and LogStream, which will expire later (see `LogRetention`, above). If set to `false`, just delete the Stack manually to clean up.

* `SoftwareRepoURL` - the Git checkout URL for this software. (The CF template does not actually contain the `splitami` codebase, only scripts to [check it out and build it][4], and to [run it][5].)

* `SoftwareVersion` - the Git branch / reference of the `splitami` codebase that is run.

Once the Stack is fully created, go to the `Outputs` tab and click on the `LogURL` to follow the software's progress. Once the program successfully completes, the ID of the output AMI will appear at the end.

----------------
Known Limitations / Bugs
----------------
* The Source AMI must be EBS-backed. S3-backed AMIs are not supported.
* Currently supports Linux only: formats all volumes as `ext4`; creates `/etc/fstab` entries.

----------------
Contribution / Development
----------------
This software was created by Benton Roberts _(benton@bentonroberts.com)_



[1]:http://cxxxx
[2]:https://github.com/benton/splitami/blob/master/cf-template.yml
[3]:https://console.aws.amazon.com/cloudformation/home
[4]:https://github.com/benton/splitami/blob/master/cf-template.yml#L55
[5]:https://github.com/benton/splitami/blob/master/cf-template.yml#L65
[6]:http://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html
