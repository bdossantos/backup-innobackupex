#!/usr/bin/env sh
#
# Script to create and restore full and incremental backups using innobackupex.
#
# Inspiration : https://gist.github.com/cdamian/931358
#

usage() {
  echo "Usage :
  $(basename $0) [options]

  Options :
    -h, --host
    -u, --user
    -p, --password
    -d, --destination
    -a, --apply-log
    -f, --full-backup
  "
}

notify() {
  logger -s -i -t $(basename $0) $1
}

while test -n "$1"; do
  case $1 in
    --host|-h)
      host=$2
      shift
      ;;
    --user|-u)
      user=$2
      shift
      ;;
    --password|-p)
      password=$2
      shift
      ;;
    --data-dir|-s)
      data_dir=$2
      shift
      ;;
    --destination|-d)
      destination=$2
      shift
      ;;
    --apply-log|-a)
      apply_log=1
      ;;
    --full-backup|-f)
      full_backup=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 3
      ;;
  esac
  shift
done

# Lock file
lock="/tmp/$(basename $0).lock"

if [ -f "${lock}" ]; then
  kill -0 $(cat $lock)
  if [ $? -eq 0 ]; then
    notify "Backup already running"
    exit 1
  fi
fi

trap "rm -rf ${lock}" INT TERM EXIT
echo $$ > "${lock}"

# MySQL host, user and password
host=${host:='127.0.0.1'}
user=${user:='root'}
test ! -z $password && password_opt="--password=${password}"

# Innobackupex log
log="/tmp/$(/usr/bin/basename $0).$$.tmp"

# Backup destination
destination=${destination:='/home/.backup/mysql'}
full_backup_dir=$destination/full
incr_backup_dir=$destination/incr

# Backup lifetime in seconds
full_backup_life=86400

# Number of full backups (and its incrementals) to keep
keep=7

processor_count=$(cat /proc/cpuinfo | grep processor | wc -l)

start=$(date +%s)

# Check if innobackupex is installed
if ! hash innobackupex 2>/dev/null; then
  notify "innobackupex not found, please ensure it is installed before proceeding."
  exit 1
fi

# Check base dir exists and is writable
if test ! -d $full_backup_dir -o ! -w $full_backup_dir; then
  notify "${full_backup_dir} does not exist or is not writable"
  exit 1
fi

# Check incr dir exists and is writable
if test ! -d $incr_backup_dir -o ! -w $incr_backup_dir; then
  notify "${incr_backup_dir} does not exist or is not writable"
  exit 1
fi

if test -z "$(mysqladmin --host=$host --user=$user $password_opt status | grep 'Uptime')"; then
  notify "HALTED : MySQL does not appear to be running."
  exit 1
fi

if ! $(echo 'exit' | mysql -s --host=$host --user=$user $password_opt); then
  notify "HALTED : Supplied mysql username or password appears to be incorrect"
  exit 1
fi

latest_full_backup=$(find $full_backup_dir \
                    -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | \
                    sort -nr | \
                    head -1)

age=$(stat -c %Y $full_backup_dir/$latest_full_backup)

if [ "$latest_full_backup" -a $(expr $age + $full_backup_life + 5) -ge $start -a ! $full_backup ]; then
  notify 'New incremental backup'

  # Check incr sub dir exists try to create if not
  if test ! -d $incr_backup_dir/$latest_full_backup; then
    mkdir $incr_backup_dir/$latest_full_backup
  fi

  # Check incr sub dir exists and is writable
  if test ! -d $incr_backup_dir/$latest_full_backup -o ! -w $incr_backup_dir/$latest_full_backup; then
    notify "${incr_backup_dir} does not exist or is not writable"
    exit 1
  fi

  latest_incr_backup=$(find $incr_backup_dir/$latest_full_backup \
                      -mindepth 1 -maxdepth 1 -type d | \
                      sort -nr | \
                      head -1)

  if test -z $latest_incr_backup; then
    notify 'This is the first incremental backup'
    incr_backup_basedir=$full_backup_dir/$latest_full_backup
  else
    notify 'This is a 2+ incremental backup'
    incr_backup_basedir=$latest_incr_backup
  fi

  notify "incremental : $incr_backup_dir/$latest_full_backup"
  notify "incremental-basedir : $incr_backup_basedir"

  # Create incremental Backup
  ionice -c 2 -n 7 \
  nice -n 10 \
  innobackupex \
    --host=$host \
    --user=$user \
    $password_opt \
    --parallel=$processor_count \
    --incremental $incr_backup_dir/$latest_full_backup \
    --incremental-basedir=$incr_backup_basedir > $log 2>&1
else
  notify 'New full backup'

  ionice -c 2 -n 7 \
  nice -n 10 \
  innobackupex \
    --host=$host \
    --user=$user \
    $password_opt \
    --parallel=$processor_count \
    $full_backup_dir > $log 2>&1

  if test ! -z $apply_log; then
    notify 'Prepare full backup'

    ionice -c 2 -n 7 \
    nice -n 15 \
    innobackupex \
      --user=$user \
      $password_opt \
      --parallel=$processor_count \
      --apply-log \
      --rebuild-indexes \
      --redo-only \
      $full_backup_dir > $log 2>&1
  fi
fi

if test -z "$(tail -1 $log | grep 'completed OK!')"; then
  notify "$INNOBACKUPEX failed:"
  notify "Error output from $INNOBACKUPEX :"
  cat $log
  rm -f $log
  exit 1
fi

current_backup=`awk -- "/Backup created in directory/ { split( \\\$0, p, \"'\" ) ; print p[2] }" $log`
notify "Databases backed up successfully to : $current_backup"

minutes=$(($full_backup_life * ($keep + 1 ) / 60))
notify "Cleaning up old backups (older than $minutes minutes)"

# Delete old bakcups
for delete in $(find $full_backup_dir -mindepth 1 -maxdepth 1 -type d -mmin +$minutes -printf "%P\n")
do
  notify "deleting $delete"
  rm -rf $full_backup_dir/$delete
  rm -rf $incr_backup_dir/$delete
done

# Delete tmp log file
rm -f $log

spent=$((($(date +%s) - $start) / 60))
notify "Backup took $spent minutes"
notify "Completed : $(/bin/date)"

exit 0
