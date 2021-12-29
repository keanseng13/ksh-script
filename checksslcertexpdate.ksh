[root@xxx sslscript]# cat checksslcertexpdate.ksh
#!/bin/ksh
CSVDIR="/etc/zabbix/sslscript"
ARCDIR="/etc/zabbix/sslscript/archive"
#MYDATE=`date +"%d-%b-%H:%M:%S"`
MYDATE=`date +"%Y-%m-%d_%H:%M:%S"`
mv $CSVDIR/certlist.csv $ARCDIR/certlist.csv.$MYDATE
cp /tmp/certlist.csv /etc/zabbix/sslscript/
chmod 644 /etc/zabbix/sslscript/certlist.csv
chown zabbix:zabbix /etc/zabbix/sslscript/certlist.csv
touch /tmp/certlist.csv

HOST=`hostname`
CURDATE_SECS=`date "+%s"`
ONEDAY_SECS='86400'
CSV_FILE='/etc/zabbix/sslscript/certlist.csv'
OUTPUT='/etc/zabbix/sslscript/sslcertexpdate.csv'
SORTOUTPUT='/etc/zabbix/sslscript/sortedsslcertexpdate.csv'
#MAILTO='IT-Infra-SSL-Support@seagate.com src.monitoring@seagate.com'
MAILTO='src.monitoring@seagate.com rachel.je.ng@seagate.com kimsiang.kang@seagate.com'
ZABSERV=`cat /etc/zabbix/extras/migration_override.conf | grep ServerActive | cut -d"=" -f2`

> $OUTPUT
> $SORTOUTPUT

tail -n +2 "${CSV_FILE}" | grep -v -e '^#' -e "^$" | while IFS=, read SERVE PORT EXPDATE REMARK
do
        if [ "$PORT" == "" ]; then
                PORT='443'
        fi
        SERVER=$(echo ${SERVE} | tr -d ' ')

        EXPIRE_DATE=`echo "Q" | timeout 60 openssl s_client -servername $SERVER -connect $SERVER:$PORT 2>/dev/null | \
                     openssl x509 -noout -dates 2>/dev/null | grep notAfter | cut -d'=' -f2`

        if [ "$EXPIRE_DATE" != "" ]; then
            EXPIRE_SECS=`date -d "${EXPIRE_DATE}" +%s`
            EXPIRE_TIME=$(( ${EXPIRE_SECS} - ${CURDATE_SECS} ))
            DAYTOEXP=$(( ${EXPIRE_TIME} / ${ONEDAY_SECS} ))
            echo "$SERVER,  $EXPIRE_DATE, $DAYTOEXP" >> $OUTPUT
            echo ""
            echo "From FrontEnd: $SERVER,  $EXPIRE_DATE, $DAYTOEXP"
            # if certificate going to expire in 10 days
            #if [ $DAYTOEXP -le 10 ]; then
            #if [ $DAYTOEXP -le 370 ]; then
                #zabbix_sender -z $ZABSERV -s "SSL Certificates Check" -k SSL.Cert.Expiry -o ${SERVER}
                zabbix_sender -c /etc/zabbix/zabbix_agentd.conf -s ${HOST} -k EXP[${SERVER}] -o ${DAYTOEXP}
                #sleep 10
            #fi
        else
            EXPIRE_SECS=`date -d "${EXPDATE}" "+%s"`
            EXPIRE_TIME=$(( ${EXPIRE_SECS} - ${CURDATE_SECS} ))
            DAYTOEXP=$(( ${EXPIRE_TIME} / ${ONEDAY_SECS} ))
            echo "$SERVER,  $EXPDATE, $DAYTOEXP" >> $OUTPUT
            echo ""
            echo "From CSV: $SERVER,  $EXPDATE, $DAYTOEXP"
            # if certificate going to expire in 10 days
            #if [ $DAYTOEXP -le 10 ]; then
                #zabbix_sender -z $ZABSERV -s "SSL Certificates Check" -k SSL.Cert.Expiry -o ${SERVER}
                zabbix_sender -c /etc/zabbix/zabbix_agentd.conf -s ${HOST} -k EXP[${SERVER}] -o ${DAYTOEXP}
                #sleep 10
            #fi

        fi
done

cat $OUTPUT | sort -t"," -k3 -k1 -g > $SORTOUTPUT
echo "Please check the attached SSL Expired Date Report" | mail -s "SSL Certs Expired Date Report"  -a $SORTOUTPUT $MAILTO
[root@xxx sslscript]#
