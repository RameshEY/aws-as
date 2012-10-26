#!/bin/bash
# launch an EC2 server and install application
# run ./launch-rds.sh first
set -eu
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # http://stackoverflow.com/questions/59895
. $DIR/setenv.sh
cd $DIR

hackconf() {	# poor man's templates; hard coded for %{DB_URL}, %{password} and %{endpoint}
  sed -e "s,%{DB_URL},$2," -e "s,%{password},$3," -e "s,%{endpoint},$4," $1.template.sh > $1
}

# figure out database connection string to put in confing/config.rb
password=`cat ~/.ec2/.dbpass`
# get the hostname for the database
endpoint=`rds-describe-db-instances $DB_INSTANCE_IDENTIFIER | head -1 | awk '{ print $9 }'`

db_url="jdbc:mysql://$endpoint:3306/archivesspace?user=aspace\&password=$password"
#                                                            ^ escaped for regex ...

if [ -z "$endpoint" ]; then		# not sure why set -u is not catching this
  echo "no endpoint, did you run launch-rds.sh?"
  exit 1
fi

# start user-data script payload
# https://help.ubuntu.com/community/CloudInit
cat > aws_init.sh << DELIM
#!/bin/bash
set -eux
# this gets run as root on the amazon machine when it boots up

# install packages we need from amazon's repo
yum -y update			# get the latest security updates
yum -y install git 
yum -y install ant 		# ant via ./build was crying about tools.jar b/c it was running in JRE
yum -y install mysql-bench	# assuming this is needed for mysql client??
# yum -y install monit		# set this up later
yum -y install tree
yum -y install libxslt		# need this for tomcat setup
# node speeds up sprockets asset pipeline generation during build
# https://github.com/joyent/node/wiki/Installing-Node.js-via-package-manager
yum -y localinstall --nogpgcheck http://nodejs.tchol.org/repocfg/amzn1/nodejs-stable-release.noarch.rpm 
yum -y install nodejs-compat-symlinks npm
npm install http-proxy		# reverse proxy for logging posts

# these aren't strictly nessicary for the application but will be usful for debugging

# iotop is a handy utility on linux
easy_install pip
pip install http://guichaz.free.fr/iotop/files/iotop-0.4.4.tar.gz
# glances looks sort of cool http://nicolargo.github.com/glances/ /via http://news.ycombinator.com/item?id=4470590
yum -y install python-devel
pip install glances

# _   /|  ack is a tool like grep, optimized for programmers
# \'o.O'  http://betterthangrep.com
# =(___)=
#    U    ack!
curl http://betterthangrep.com/ack-standalone > /usr/local/bin/ack && chmod 0755 /usr/local/bin/ack

# redirect port 8080 to port 80 so we don't have to run tomcat as root
# http://forum.slicehost.com/index.php?p=/discussion/2497/iptables-redirect-port-80-to-port-8080/p1
iptables -A PREROUTING -t nat -i eth0 -p tcp --dport 80 -j REDIRECT --to-port 8080

# create role account for the application
useradd aspace
# remember this is just session storage, this is just for creating a test server
# move the application home directory onto the bigger disk
mv /home/aspace /media/ephemeral0/aspace
ln -s /media/ephemeral0/aspace /home/aspace

# create script to setup the role account and set permissions
touch ~aspace/init.sh
chown aspace:aspace ~aspace/init.sh
chmod 700 ~aspace/init.sh
# write the file
cat > ~aspace/init.sh <<EOSETUP
DELIM
# as_role_account.sh is created from as_role_account.sh.template.sh
# it is run as the aspace role account on the target machine 
# a poor sed based template system is used (switch to better perl oneliner)
# to hack sensitive info into the script
hackconf as_role_account.sh $db_url $password $endpoint
# cat the script into the payload
cat as_role_account.sh >> aws_init.sh 

# finish off the user-data payload file
cat >> aws_init.sh << DELIM
EOSETUP
su - aspace -c ~aspace/init.sh
rm ~aspace/init.sh 
## chkconfig an init.d script that will start and stop monit
DELIM
# back to the local machine

gzip aws_init.sh
# clean up
rm as_role_account.sh 

# http://docs.amazonwebservices.com/AWSEC2/latest/CommandLineReference/ApiReference-cmd-RunInstances.html
# "You must have the key pair where you run your script." -- https://forums.aws.amazon.com/message.jspa?messageID=88003
ec2-run-instances $AMI                \
     --verbose                        \
     --user-data-file aws_init.sh.gz  \
     --key ec2-keypair                \
     --monitor                        \
     --instance-type m1.small         \
     --availability-zone $ZONE

# clean up
rm aws_init.sh.gz
