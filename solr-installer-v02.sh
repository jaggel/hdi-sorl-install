#!/usr/bin/env bash

installAndStartSolr() {
echo "Adding Solr's Upstart configuration"
useradd -r solruser
chown -R solruser:solruser /usr/hdp/current/solr/

if [ -z "$ZKHOSTS" ]; then
    echo "[ERROR] ZKHOSTS is empty. Exiting..."
    exit 1
fi

cat >/etc/init/solr.conf <<EOL
start on runlevel [2345]
stop on runlevel [016]
respawn
respawn limit 10 5

setuid solruser
setgid solruser

script
    cd /usr/hdp/current/solr/example
    java -DzkHost=$ZKHOSTS -Dcollection.configName=hditestconfig -jar start.jar 1>> logs/solr.stdout.log 2>> logs/solr.stderr.log
end script
EOL
cat >/etc/systemd/system/multi-user.target.wants/solr.service <<EOL
[[Unit]
Description=solr service

[Service]
Type=simple
User=solruser
Group=solruser
Restart=always
RestartSec=5
WorkingDirectory=/usr/hdp/current/solr/example
ExecStart=/usr/bin/java -DzkHost=$ZKHOSTS -Dcollection.configName=hditestconfig -jar /usr/hdp/current/solr/example/start.jar

[Install]
WantedBy=multi-user.target
EOL
	if [[ $OS_VERSION == 16* ]]; then
         echo "Using systemd configuration"	
	     systemctl daemon-reload
         systemctl start solr		
	else
         echo "Using upstart configuration"
	     initctl reload-configuration
         start solr		
    fi
}

# Import the helper method module.
wget -O /tmp/HDInsightUtilities-v01.sh -q https://hdiconfigactions.blob.core.windows.net/linuxconfigactionmodulev01/HDInsightUtilities-v01.sh && source /tmp/HDInsightUtilities-v01.sh && rm -f /tmp/HDInsightUtilities-v01.sh

if [ `test_is_zookeepernode` == 1 ]; then
    echo "Solr cannot be installed on Zookeeper nodes. Exiting..."
    exit 0
fi

OS_VERSION=$(lsb_release -sr)
echo "OS Version is $OS_VERSION"

# In case Solr is installed, exit.
if [ -e /usr/hdp/current/solr ]; then
    echo "Solr is already installed, exiting ..."
    exit 0
fi

# Download Solr binary to temporary location.

 echo "Downloading Solr binaries"
 #download_file http://archive.apache.org/dist/lucene/solr/4.9.0/solr-4.9.0.tgz /tmp/solr-4.9.0.tgz
 download_file http://archive.apache.org/dist/lucene/solr/4.9.0/solr-7.1.0.tgz /tmp/solr-7.1.0.tgz
	  
 # Untar the Solr binary and move it to proper location.
 untar_file /tmp/solr-7.1.0.tgz /usr/hdp/current
 mv /usr/hdp/current/solr-7.1.0 /usr/hdp/current/solr

 # Remove the temporary file downloaded.
 rm -f /tmp/solr-7.1.0.tgz

# Configure Solr
cd /usr/hdp/current/solr/example

ZKHOSTS=`grep -R zookeeper /etc/hadoop/conf/yarn-site.xml | grep 2181 | grep -oPm1 "(?<=<value>)[^<]+"`
if [ -z "$ZKHOSTS" ]; then
    ZKHOSTS=`grep -R zk /etc/hadoop/conf/yarn-site.xml | grep 2181 | grep -oPm1 "(?<=<value>)[^<]+"`
fi

echo "List of zookeeper hosts: $ZKHOSTS"
syncFile=$(sed -n -e 's/zookeepernode[0-9]*.\([-a-zA-Z0-9]*\).*/\1/p' <<< $ZKHOSTS)
if [ -z "$syncFile" ]; then
    syncFile=$(sed -n -e 's/zk[-a-zA-Z0-9]*.\([-a-zA-Z0-9]*\).*/\1/p' <<< $ZKHOSTS)
fi

echo "SyncFile=$syncFile"

if [ -z "$syncFile" ]; then
	echo "Invalid zookeepernode URLs. Exiting..."
	exit 1
fi

syncFileExists=$(hadoop fs -ls / | grep $syncFile | wc -l)

if [[ $syncFileExists == 0 ]]; then
    echo "Creating sync file on WASB"
    hadoop fs -touchz wasb:///$syncFile
    echo "Configuring Zookeeper's Solr config."
    scripts/cloud-scripts/zkcli.sh -cmd upconfig -zkhost $ZKHOSTS -d solr/collection1/conf/ -n hditestconfig
    scripts/cloud-scripts/zkcli.sh -cmd linkconfig -zkhost $ZKHOSTS -collection collection1 -confname hditestconfig -solrhome solr
    scripts/cloud-scripts/zkcli.sh -cmd bootstrap -zkhost $ZKHOSTS -solrhome solr
else
    echo "Sync file already exists. Skipping Zookeeper configuration."
    echo "Sleeping for 60 seconds to ensure Zookeeper is fully configured."
    sleep 60
fi

echo "Starting Solr."
installAndStartSolr