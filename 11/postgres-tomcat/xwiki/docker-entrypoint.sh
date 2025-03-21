#!/bin/bash
# ---------------------------------------------------------------------------
# See the NOTICE file distributed with this work for additional
# information regarding copyright ownership.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 2.1 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.
# ---------------------------------------------------------------------------

set -e

function first_start() {
  configure
  touch /usr/local/tomcat/webapps/ROOT/.first_start_completed
}

function other_starts() {
  mkdir -p /usr/local/xwiki/data
  restoreXWikiConfigurationFile 'hibernate.cfg.xml'
  restoreXWikiConfigurationFile 'xwiki.cfg'
  restoreXWikiConfigurationFile 'xwiki.properties'
  restoreTomcatConfigurationFile 'server.xml'
}

# $1 - the path to xwiki.[cfg|properties]
# $2 - the setting/property to set
# $3 - the new value
function xwiki_replace() {
  sed -i s~"\#\? \?$2 \?=.*"~"$2=$3"~g "$1"
}

# $1 - the setting/property to set
# $2 - the new value
function xwiki_set_cfg() {
  xwiki_replace /usr/local/tomcat/webapps/ROOT/WEB-INF/xwiki.cfg "$1" "$2"
}

# $1 - the setting/property to set
# $2 - the new value
function xwiki_set_properties() {
  xwiki_replace /usr/local/tomcat/webapps/ROOT/WEB-INF/xwiki.properties "$1" "$2"
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
    exit 1
  fi
  local val="$def"
  if [ "${!var:-}" ]; then
    val="${!var}"
  elif [ "${!fileVar:-}" ]; then
    val="$(< "${!fileVar}")"
  fi
  export "$var"="$val"
  unset "$fileVar"
}

# Allows to use sed but with user input which can contain special sed characters such as \, / or &.
# $1 - the text to search for
# $2 - the replacement text
# $3 - the file in which to do the search/replace
function safesed {
  sed -i "s/$(echo $1 | sed -e 's/\([[\/.*]\|\]\)/\\&/g')/$(echo $2 | sed -e 's/[\/&]/\\&/g')/g" $3
}

# $1 - the config file name found in WEB-INF (e.g. "xwiki.cfg")
function saveTomcatConfigurationFile() {
  saveConfigurationFile '/usr/local/tomcat/conf/' $1
}

# $1 - the config file name to restore in WEB-INF (e.g. "xwiki.cfg")
function restoreTomcatConfigurationFile() {
  restoreConfigurationFile '/usr/local/tomcat/conf/' $1
}

# $1 - the config file name found in WEB-INF (e.g. "xwiki.cfg")
function saveXWikiConfigurationFile() {
  saveConfigurationFile '/usr/local/tomcat/webapps/ROOT/WEB-INF/' $1
}

# $1 - the config file name to restore in WEB-INF (e.g. "xwiki.cfg")
function restoreXWikiConfigurationFile() {
  restoreConfigurationFile '/usr/local/tomcat/webapps/ROOT/WEB-INF/' $1
}

# $1 - the path where the referenced config file is found, e.g. /usr/local/tomcat/conf/
# $2 - the config file found in $1
function saveConfigurationFile() {
  if [ -f "/usr/local/xwiki/data/$2" ]; then
     echo "  Reusing existing config file $1$2..."
     cp "/usr/local/xwiki/data/$2" "$1$2"
  else
     echo "  Saving config file $1$2..."
     cp "$1$2" "/usr/local/xwiki/data/$2"
  fi
}

# $1 - the path where the referenced config file is found, e.g. /usr/local/tomcat/conf/
# $2 - the config file found in $1
function restoreConfigurationFile() {
  if [ -f "/usr/local/xwiki/data/$2" ]; then
     echo "  Synchronizing config file $1$2..."
     cp "/usr/local/xwiki/data/$2" "$1$2"
  else
     echo "  No config file $1$2 found, using default from container..."
     cp "$1$2" "/usr/local/xwiki/data/$2"
  fi
}

function configure() {
  echo 'Configuring XWiki...'

  echo 'Setting environment variables'
  file_env 'DB_USER' 'xwiki'
  file_env 'DB_PASSWORD' 'xwiki'
  file_env 'DB_HOST' 'db'
  file_env 'DB_DATABASE' 'xwiki'
  file_env 'INDEX_HOST' 'localhost'
  file_env 'INDEX_PORT' '8983'

  echo 'Replacing environment variables in files'
  safesed "replaceuser" $DB_USER /usr/local/tomcat/webapps/ROOT/WEB-INF/hibernate.cfg.xml
  safesed "replacepassword" $DB_PASSWORD /usr/local/tomcat/webapps/ROOT/WEB-INF/hibernate.cfg.xml
  safesed "replacecontainer" $DB_HOST /usr/local/tomcat/webapps/ROOT/WEB-INF/hibernate.cfg.xml
  safesed "replacedatabase" $DB_DATABASE /usr/local/tomcat/webapps/ROOT/WEB-INF/hibernate.cfg.xml

  echo '  Generating authentication validation and encryption keys...'
  xwiki_set_cfg 'xwiki.authentication.validationKey' "$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
  xwiki_set_cfg 'xwiki.authentication.encryptionKey' "$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
  echo '  Deploying XWiki in the ROOT context'
  xwiki_set_cfg 'xwiki.webapppath' ""

  echo '  Setting permanent directory...'
  xwiki_set_properties 'environment.permanentDirectory' '/usr/local/xwiki/data'
  echo '  Configure libreoffice...'
  xwiki_set_properties 'openoffice.autoStart' 'true'

  if [ $INDEX_HOST != 'localhost' ]; then
    echo '  Configuring remote Solr Index'
    xwiki_set_properties 'solr.type' 'remote'
    xwiki_set_properties 'solr.remote.url' "http://$INDEX_HOST:$INDEX_PORT/solr/xwiki"
  fi

  # If the files already exist then copy them to the XWiki's WEB-INF directory. Otherwise copy the default config
  # files to the permanent directory so that they can be easily modified by the user. They'll be synced at the next
  # start.
  mkdir -p /usr/local/xwiki/data
  saveXWikiConfigurationFile 'hibernate.cfg.xml'
  saveXWikiConfigurationFile 'xwiki.cfg'
  saveXWikiConfigurationFile 'xwiki.properties'

  saveTomcatConfigurationFile 'server.xml'
}

# This if will check if the first argument is a flag but only works if all arguments require a hyphenated flag
# -v; -SL; -f arg; etc will work, but not arg1 arg2
if [ "${1:0:1}" = '-' ]; then
    set -- xwiki "$@"
fi

# Check for the expected command
if [ "$1" = 'xwiki' ]; then
  if [[ ! -f /usr/local/tomcat/webapps/ROOT/.first_start_completed ]]; then
    first_start
  else
    other_starts
  fi
  shift
  set -- catalina.sh run "$@"
fi

# Else default to run whatever the user wanted like "bash"
exec "$@"
