root@xxx:/export/home/jobmon/ora/scripts#cat ora_job_error.ksh
#!/bin/ksh

# ora_job_error.ksh

ENV=~/ora/conf/${USER}.env
if [ -r $ENV ]; then
   . $ENV
   if [ $? -ne 0 ]; then
      echo "ERROR: Unable to load environment file $ENV"
      exit 1
   fi
else
   echo "ERROR: Environment file $ENV is not readable or does not exist."
   exit 1
fi

if [ -r "$CONFDIR/${BASENAME//.ksh/.env}" ]; then
   . "$CONFDIR/${BASENAME//.ksh/.env}"
fi

FOOTER="$(date)  $LOGNAME@$(hostname):$0"

CSV_DOWN="/export/home/jobmon/ora/conf/dbdowntime.csv"
CURDAY=`date '+%A'`
CURTIME=`date +"%H%M"`

isweeklymaint() {
  MAINTDAY=`cat $CSV_DOWN | grep $3 | cut -d"," -f2`
  MAINTTF=`cat $CSV_DOWN | grep $3 | cut -d"," -f3`
  MAINTTT=`cat $CSV_DOWN | grep $3 | cut -d"," -f4`

  if [[ "$CURDAY" == "$MAINTDAY" && $MAINTTF -le $CURTIME && $MAINTTT -ge $CURTIME ]]; then
    # 0 = true
    return 0
  else
    # 1 = false
    return 1
  fi
}

trigalerttozab() {
  CRITPERIOD="/export/home/jobmon/ora/conf/JobmonCriticalPeriodsToZabbix.csv"
  CURDATE_SECS=`date "+%s"`
  JOBNAMEKEY=$(echo $JOBNAME | sed 's\[() ]\.\g')

  echo "This alert need to go to Zabbix - $JOBNAME"
  echo "Checking the Critical Period Table"
  tail -n +2 "${CRITPERIOD}" |grep "${PERIODX}" | while IFS=, read PERIOD MONTH DATEFR DATETO REMARK
  do
        echo "${PERIOD} is the period"
        echo "Date from is ${DATEFR} ------ Date to is ${DATETO}"

        DATEFRSEC=`date -d "${DATEFR}" "+%s"`
        DATETOSEC=`date -d "${DATETO}" "+%s"`

        if [[ $DATEFRSEC -le $CURDATE_SECS && $DATETOSEC -ge $CURDATE_SECS ]]; then
                echo "Send alert to Zabbix - $JOBNAME"
                ZABKEY=$1"["$JOBNAMEKEY"]"
                zabbix_sender -c /etc/zabbix/zabbix_agentd.conf -s sgmpcjobmon1 -k ${ZABKEY} -o $2
        fi

  done
}

cleanup() {
   rm -f $TMPFILE $TMPFILE.* > /dev/null 2>&1
}

log() {
   echo -e "$(date) : $1"
   echo -e "$1" >> $SUPPORT_LOG 2>&1
}

incrementFileCounter() {
   unset x
   x=`tail -1 "$CTR_FILE" 2>/dev/null`
   let x=x+1 2>/dev/null || x=1
   echo "$x" > "$CTR_FILE"
   CONS_FAILS=$x
   if [ $CONS_FAILS -gt 1 ]; then
      CONS_FAILS="This job has experienced $CONS_FAILS consecutive failures."
   else
      CONS_FAILS=""
   fi
}

check_concurrent_job() {
  for database in $DB
  do
    if isweeklymaint $CURDAY $CURTIME $database; then
       echo "----- Skip $JOBNAME, it is weekly maintenance for $database on $CURDAY at $CURTIME"
       continue
    fi

    if [ "$NEWSCRIPT" = "Y" ]; then
        sqlscript="ora_job_error_new.sql"
    else
        sqlscript="ora_job_error.sql"
    fi

    timeout 60 sqlplus -S okcmonitor1/$(readpwd $database okcmonitor1)@$database <<EOF > $TMPFILE 2>&1
@$SQLDIR/format_fndjob.sql
WHENEVER SQLERROR EXIT SQL.SQLCODE;
WHENEVER OSERROR EXIT FAILURE;
@$SQLDIR/$sqlscript "$JOBNAME" "$USERNAME"
EOF

    if [ $? -ne 0 ]; then
      log "ERROR: Unable to connect to $database to check $JOBNAME errors\n$(cat $TMPFILE)"
    else
      if [ -s $TMPFILE ]; then
        INSTANCE=$(echo $database |tr [:lower:] [:upper:])
        sed -i -e 's/^[^$]*$/"&"/' -e 's/\s*"\s*/"/g' $TMPFILE  #quote beg and end of lines
        grep $INSTANCE $TMPFILE |while read LINE
        do
          STATUS=$(echo $LINE |awk -F',' '{print $9}' |sed 's/\"//g')
          ORAUSER=$(echo $LINE |awk -F',' '{print $3}' |sed 's/\"//g;s/ //g' )
          CTR_FILE=$DATADIR/${JOBNAMEb}.${ORAUSER}.ctr
          echo "$JOBNAME -$database, completion status $STATUS"
          if [[ "$STATUS" = "Error" && "$ERRCHECK" = "Y" ]] || [[ "$STATUS" = "Warning" && "$WARNCHECK" = "Y" ]]; then
          #if [[ "$STATUS" = "Error" || "$STATUS" = "Warning" ]]; then
            SHORT_DESC="$INSTANCE: $JOBNAME Error/ Warning: $ORAUSER"
            DATA_FILE=$LOGDIR/${database}_${JOBNAMEb}.${ORAUSER}.error.$(date "+%d%b%Y_%H%M%S").csv
            grep -v "$JOBNAME" $TMPFILE > $DATA_FILE
            echo $LINE >> $DATA_FILE
            incrementFileCounter

            if [ "${ZABBIXYESb}" == "Y" ]; then
                trigalerttozab error $INSTANCE
            fi
            $COMMONDIR/scripts/mon_escalation2.ksh "$DATA_FILE" "$SNOW" "$SNCI" "$SNGRP" "$ASSIGNED" "2" "$SHORT_DESC" "$ESCALATION" "$EMAIL" "" "JOB \"$JOBNAME\" on $INSTANCE user $ORAUSER has failed.

$CONS_FAILS

$(cat $DATA_FILE)

$FOOTER


Application: $KBA"
          else                                     #Job ran and completed without error
            rm -f $CTR_FILE > /dev/null 2>&1
          fi
        done
        rm -f $TMPFILE > /dev/null 2>&1
      else
        echo "$JOBNAME -$database, did not run"           #Job did not run in the past hour
      fi
    fi
  done
}

check_longrunning() {
  for database in $DB
  do
    if isweeklymaint $CURDAY $CURTIME $database; then
       echo "----- Skip $JOBNAME, it is weekly maintenance for $database on $CURDAY at $CURTIME"
       continue
    fi

    if [ "$NEWSCRIPT" = "Y" ]; then
        sqlscript="ora_job_longrun_new.sql"
    else
        sqlscript="ora_job_longrun.sql"
    fi

    sqlplus -S okcmonitor1/$(readpwd $database okcmonitor1)@$database <<EOF > $TMPFILE 2>&1
@$SQLDIR/format_fndjob.sql
WHENEVER SQLERROR EXIT SQL.SQLCODE;
WHENEVER OSERROR EXIT FAILURE;
@$SQLDIR/$sqlscript "$JOBNAME" $MAXMINUTES "$USERNAME"
EOF

    if [ $? -ne 0 ]; then
      log "ERROR: Unable to connect to $database to check long running $JOBNAME \n$(cat $TMPFILE)"
    else
      if [ -s $TMPFILE ]; then
        INSTANCE=$(echo $database |tr [:lower:] [:upper:])
        sed -i -e 's/^[^$]*$/"&"/' -e 's/\s*"\s*/"/g' $TMPFILE  #quote beg and end of lines
        grep $INSTANCE $TMPFILE |while read LINE
        do
          ORAUSER=$(echo $LINE |awk -F ',' '{print $2}' |sed 's/\"//g;s/ //g')
          SHORT_DESC="$INSTANCE: $JOBNAME is Running Long: $ORAUSER"
          DATA_FILE=$LOGDIR/${database}_${JOBNAMEb}.${ORAUSER}.longrun.$(date "+%d%b%Y_%H%M%S").csv
          grep -v "$JOBNAME" $TMPFILE > $DATA_FILE
          echo $LINE >> $DATA_FILE
          echo "$JOBNAME -$database, running long"
          $COMMONDIR/scripts/mon_escalation2.ksh "$DATA_FILE" "$SNOW" "$SNCI" "$SNGRP" "$ASSIGNED" "2" "$SHORT_DESC" "$ESCALATION" "$EMAIL" "" "JOB \"$JOBNAME\" on $INSTANCE user $ORAUSER is running long.

$(cat $DATA_FILE)

$FOOTER


Application: $KBA"
        done
      fi
      rm $TMPFILE  2>/dev/null
    fi
  done
}

check_report_set() {
  for database in $DB
  do
    if isweeklymaint $CURDAY $CURTIME $database; then
       echo "----- Skip $JOBNAME, it is weekly maintenance for $database on $CURDAY at $CURTIME"
       continue
    fi

    if [ "$NEWSCRIPT" = "Y" ]; then
        sqlscript="ora_rptset_error_new.sql"
    else
        sqlscript="ora_rptset_error.sql"
    fi

    sqlplus -s okcmonitor1/$(readpwd $database okcmonitor1)@$database <<EOF > $TMPFILE 2>&1
@$SQLDIR/format_fndjob.sql
WHENEVER SQLERROR EXIT SQL.SQLCODE;
WHENEVER OSERROR EXIT FAILURE;
@$SQLDIR/$sqlscript "$JOBNAME" "$USERNAME"
EOF

    if [ $? -ne 0 ]; then
      log "ERROR: Unable to connect to $database to check $JOBNAME errors\n$(cat $TMPFILE)"
    else
      if [ -s $TMPFILE ]; then
        INSTANCE=$(echo $database |tr [:lower:] [:upper:])
        sed -i -e 's/^[^$]*$/"&"/' -e 's/\s*"\s*/"/g' $TMPFILE  #quote beg and end of lines
        grep "$JOBNAME" $TMPFILE |while read LINE
        do
          STATUS=$(echo $LINE |awk -F',' '{print $6}' |sed 's/\"//g')
          ORAUSER=$(echo $LINE |awk -F',' '{print $2}' |sed 's/\"//g;s/ //g')
          CTR_FILE=$DATADIR/${JOBNAMEb}.${ORAUSER}.ctr
          echo "$JOBNAME -$database, completion status $STATUS"
          if [[ "$STATUS" = "Error" || "$STATUS" = "Warning" ]]; then
            SHORT_DESC="$INSTANCE: $JOBNAME Report Set Error/Warning: $ORAUSER"
            DATA_FILE=$LOGDIR/${database}_${JOBNAMEb}.${ORAUSER}.error.$(date "+%d%b%Y_%H%M%S").csv
            grep -v "$JOBNAME" $TMPFILE > $DATA_FILE
            echo $LINE >> $DATA_FILE
            incrementFileCounter

            if [ "${ZABBIXYESb}" == "Y" ]; then
                trigalerttozab error $INSTANCE
            fi
            $COMMONDIR/scripts/mon_escalation2.ksh "$DATA_FILE" "$SNOW" "$SNCI" "$SNGRP" "$ASSIGNED" "2" "$SHORT_DESC" "$ESCALATION" "$EMAIL" "" "JOB \"$JOBNAME\" on $INSTANCE user $ORAUSER has failed.

$CONS_FAILS

$(cat $DATA_FILE)
$FOOTER


Application: $KBA"
          else                               #Job ran without error
            rm -f $CTR_FILE > /dev/null 2>&1
          fi
        done
      else                                   #Job did not run in the last hour
        echo "$JOBNAME -$database, did not run"
      fi
      rm $TMPFILE 2>/dev/null
    fi
  done
}

check_rpt_set_longrun() {
  for database in $DB
  do
    if isweeklymaint $CURDAY $CURTIME $database; then
       echo "----- Skip $JOBNAME, it is weekly maintenance for $database on $CURDAY at $CURTIME"
       continue
    fi

    if [ "$NEWSCRIPT" = "Y" ]; then
        sqlscript="ora_rptset_longrun_new.sql"
    else
        sqlscript="ora_rptset_longrun.sql"
    fi

    sqlplus -S okcmonitor1/$(readpwd $database okcmonitor1)@$database <<EOF > $TMPFILE 2>&1
@$SQLDIR/format_fndjob.sql
WHENEVER SQLERROR EXIT SQL.SQLCODE;
WHENEVER OSERROR EXIT FAILURE;
@$SQLDIR/$sqlscript "$JOBNAME" $MAXMINUTES "$USERNAME"
EOF

    if [ $? -ne 0 ]; then
      log "ERROR: Unable to connect to $database to check long running $JOBNAME \n$(cat $TMPFILE)"
    else
      if [ -s $TMPFILE ]; then
        INSTANCE=$(echo $database |tr [:lower:] [:upper:])
        sed -i -e 's/^[^$]*$/"&"/' -e 's/\s*"\s*/"/g' $TMPFILE  #quote beg and end of lines
        grep $INSTANCE $TMPFILE |while read LINE
        do
          ORAUSER=$(echo $LINE |awk -F ',' '{print $2}' |sed 's/\"//g;s/ //g')
          SHORT_DESC="$INSTANCE: $JOBNAME is Running Long: $ORAUSER"
          DATA_FILE=$LOGDIR/${database}_${JOBNAMEb}.${ORAUSER}.longrun.$(date "+%d%b%Y_%H%M%S").csv
          head -2 $TMPFILE > $DATA_FILE
          echo $LINE >> $DATA_FILE
          echo "$JOBNAME -$database, running long"
          $COMMONDIR/scripts/mon_escalation2.ksh "$DATA_FILE" "$SNOW" "$SNCI" "$SNGRP" "$ASSIGNED" "2" "$SHORT_DESC" "$ESCALATION" "$EMAIL" "" "JOB \"$JOBNAME\" on $INSTANCE user $ORAUSER is running long.

$(cat $DATA_FILE)
$FOOTER


Application: $KBA"
        done
        rm $TMPFILE 2>/dev/null

      fi
    fi
  done
}

check_queue() {
  for database in $DB
  do
    if isweeklymaint $CURDAY $CURTIME $database; then
       echo "----- Skip $JOBNAME checking, it is weekly maintenance for $database on $CURDAY at $CURTIME"
       continue
    fi

    sqlplus -s okcmonitor1/$(readpwd $database okcmonitor1)@$database <<EOF > $TMPFILE 2>&1
@$SQLDIR/format_fndjob.sql
WHENEVER SQLERROR EXIT SQL.SQLCODE;
WHENEVER OSERROR EXIT FAILURE;
@$SQLDIR/ora_cmgr.sql $JOBNAME
EOF

    if [ $? -ne 0 ]; then
      log "ERROR: Unable to connect to $database to check $JOBNAME \n$(cat $TMPFILE)"
    else
      if [ -s $TMPFILE ]; then
        INSTANCE=$(echo $database |tr [:lower:] [:upper:])
        sed -i -e 's/^[^$]*$/"&"/' -e 's/\s*"\s*/"/g' $TMPFILE  #quote beg and end of lines
        SHORT_DESC="$INSTANCE: $JOBNAME Concurrent Manager Down"
        DATA_FILE=$LOGDIR/${database}_${JOBNAMEb}.error.$(date "+%d%b%Y_%H%M%S").csv
        mv $TMPFILE $DATA_FILE
        echo "$JOBNAME -$database, error"
        $COMMONDIR/scripts/mon_escalation2.ksh "$DATA_FILE" "$SNOW" "$SNCI" "$SNGRP" "$ASSIGNED" "2" "$SHORT_DESC" "$ESCALATION" "$EMAIL" "" "Concurrent Manager \"$JOBNAME\" on $INSTANCE is not running.

$FOOTER


Application: $KBA"
      else
        echo "$JOBNAME -$database, okay"
        rm $TMPFILE 2>/dev/null
      fi
    fi
  done
}
####### MAIN CODE ############

tail -n +3 "$CSV_FILE" |sed -e 's/\r//g' -e 's/[[:blank:]]*,[[:blank:]]*/,/g' |while IFS=, read APP JOBNAME JOBTYPE ERRCHECK WARNCHECK LRCHECK LRTHRESHOLD SOX SNOW EALERT EMAIL SNGRP ASSIGNED SNCI ZABBIXYES KBA PERIODX KBANUM REMARKS NEWSCRIPT USERNAME
do

#TEST VARIABLES
if [ "$TEST_EMAIL" != "" ]; then
  EMAIL=$TEST_EMAIL
fi

  ASSIGNED=$(echo $ASSIGNED | tr '|' ',')
  JOBNAME=$(echo $JOBNAME | tr '|' ',')
  JOBNAMEb=$(echo "$JOBNAME" |tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]')
  ZABBIXYESb=$(echo "$ZABBIXYES" | tr [:lower:] [:upper:])

  TMPFILE=$LOGDIR/${JOBNAMEb}.tmp

  case $APP in
   ERP)
     DB="pwap1"
     ;;
   ISS)
     DB="ampissc1 ampissn1 eupissc1 aspissc1 aspissn1 eupissn1 aspissn2"
     ;;
   PCAP)
     DB="pcap1"
     ;;
   *)
     DB="$(echo $APP |tr [:upper:] [:lower:])"
     ;;
  esac

  for database in "$DB"; do
    tnsping $database >/dev/null
    if [ $? -ne 0 ]; then
      log "$database does not respond to tnsping :$JOBNAME\n"
      continue 2
    fi
  done

  case "$JOBTYPE" in
  "Concurrent Job")
      check_concurrent_job
      if [ "$LRCHECK"  = "Y" ]; then
        MAXMINUTES=$(echo $LRTHRESHOLD |awk '{print $2}')
        check_longrunning
      fi
      ;;
  "Concurrent job queue")
      check_queue
      ;;
  "Report Set")
      check_report_set
      if [ "$LRCHECK"  = "Y" ]; then
        MAXMINUTES=$(echo $LRTHRESHOLD |awk '{print $2}')
        check_rpt_set_longrun
      fi
      ;;
  *)
      log "$JOBNAME in $CSV_FILE does not have a valid Job Type assigned: $JOBTYPE"
  esac

done

if [ -s $SUPPORT_LOG ]; then
  cat $SUPPORT_LOG |mutt -s "$BASENAME error" -- $JOBSUPPORT
fi

cleanup
root@xxx:/export/home/jobmon/ora/scripts#
