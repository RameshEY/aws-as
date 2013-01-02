#!/bin/bash
# launch an EC2 server, build the application, upload to S3
set -eu
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # http://stackoverflow.com/questions/59895
. $DIR/setenv.sh
cd $DIR

# start user-data script payload
# https://help.ubuntu.com/community/CloudInit
cat > aws_builder_init.sh << DELIM
#!/bin/bash
set -eux
# this gets run as root on the amazon machine when it boots up

# let's log http://alestic.com/2010/12/ec2-user-data-output
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# set up a self destruct in case any of these commands don't work for some reason
echo halt | at now + 175 minutes

# mkdir /media/ephemeral0/aspace
# cd /media/ephemeral0/aspace

apt-get -y install xvfb firefox imagemagick
apt-get -y install nodejs
apt-get -y install git zip
apt-get -y install openjdk-6-jdk
# for blitz.io
apt-get -y install rubygems
gem install blitz
iptables -A PREROUTING -t nat -i eth0 -p tcp --dport 80 -j REDIRECT --to-port 8080

git clone https://github.com/archivesspace/archivesspace.git
cd archivesspace
./build/run bootstrap 
./build/run backend:integration 
./build/run backend:doc
./build/run backend:test
./build/run backend:coverage
./build/run common:test
SCREENSHOT_ON_ERROR=1 xvfb-run --server-args="-screen 0 1024x768x24" ./build/run selenium:test
./build/run dist
./build/run backend:war
./build/run frontend:war
zip -q -r build.zip build config backend
zip -d build.zip "*mysql-connector*"
DELIM

./upload_files.py $TAG >> aws_builder_init.sh

cat >> aws_builder_init.sh << DELIM
# send a notice to irc
(
echo NICK cdlbuildbot 
echo USER cdlbuildbot 8 \* : Notifier
sleep 10 
echo 'JOIN #archivesspace'
sleep 5
echo "PRIVMSG #archivesspace : $TAG built and files uploaded to s3 https://s3.amazonaws.com/archivesspace/public-files/archivesspace.$TAG.jar"
sleep 5
echo QUIT
sleep 5
) | nc chat.freenode.net 6667
halt
set -e
## blitz
blitz api:init <<EEOOMM
DELIM
head -2 ~/.ec2/blitz.txt >> aws_builder_init.sh 
cat >> aws_builder_init.sh << DELIM

EEOOMM
set +e

# do blitz test
export PUBLIC_IP=\`curl http://instance-data/latest/meta-data/public-ipv4\`
java -jar archivesspace.jar > /dev/null 2>&1 &
sleep 90
# do a sprint
blitz curl -T 5000 http://\$PUBLIC_IP/
echo '42' > /root/ArchivesSpace/tmp/jetty-0.0.0.0-8080-frontend-_-any-/webapp/$BLITZ_RUSH
sleep 5
# do a rush
blitz curl -p 1-500:60 -T 5000 http://\$PUBLIC_IP/

DELIM

# back to the local machine

gzip aws_builder_init.sh

# http://docs.amazonwebservices.com/AWSEC2/latest/CommandLineReference/ApiReference-cmd-RunInstances.html
# "You must have the key pair where you run your script." -- https://forums.aws.amazon.com/message.jspa?messageID=88003
ec2-run-instances $UB_IN_AMI          \
     --verbose                        \
     --user-data-file aws_builder_init.sh.gz  \
     --key ec2-keypair                \
     --monitor                        \
     --instance-type m1.large         \
     --availability-zone $ZONE

# clean up
rm aws_builder_init.sh.gz
