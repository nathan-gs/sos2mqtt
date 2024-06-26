#!/usr/bin/env bash

IS_SILENT=false
TS_DELAY="30 minutes ago"
USE_MQTT=false
MQTT_TOPIC_PREFIX="sos2mqtt/"
MQTT_PUBLISH_HA_DISCOVERY=true
MQTT_HOST="localhost"
STATIONS_LIST=""

help() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --silent"
  echo "  --base-url <url>"
  echo "  --ts-delay <delay> (default: 30 minutes ago)"
  echo "  --mqtt-user <user>"
  echo "  --mqtt-password <password>"
  echo "  --mqtt-host <host> (default: localhost)"
  echo "  --mqtt-topic-prefix <prefix> (default: sos2mqtt/)"
  echo "  --mqtt-publish-ha <true|false> (default: true)"
  echo "  --stations-list <station1,station2,...>"

  echo "  if --mqtt-user is set, mqtt will be used"

}

OPTS=$(getopt -o h --long 'help,silent,base-url:,ts-delay:,mqtt-user:,mqtt-password:,mqtt-host:,mqtt-topic-prefix:,mqtt-publish-ha:,stations-list:' -- "$@")

eval set -- "$OPTS"

while :
do
  case "$1" in
    --silent )
      IS_SILENT=true
      shift 1
      ;;
    --base-url )
      BASE_URL="$2"
      shift 2
      ;;
    --ts-delay )
      TS_DELAY="$2"
      shift 2
      ;;
    --mqtt-user )
      USE_MQTT=true
      MQTT_USER="$2"
      shift 2
      ;;
    --mqtt-password )
      MQTT_PASSWORD="$2"
      shift 2
      ;;
    --mqtt-host )
      MQTT_HOST="$2"
      shift 2
      ;;
    --mqtt-topic-prefix )
      MQTT_TOPIC_PREFIX="$2"
      shift 2
      ;;
    --mqtt-publish-ha )
      MQTT_PUBLISH_HA_DISCOVERY="$2"
      shift 2
      ;;
    --stations-list )
      STATIONS_LIST="$2"
      shift 2
      ;;
    --help)
      help
      shift 1
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      exit 1
      ;;
  esac
done


if [ -z "$BASE_URL" ];
then
  echo "Missing --base-url, check $0 --help for more info."
  exit 1
fi

log() {
  if [ "$IS_SILENT" = false ];
  then
    echo $1
  fi
}

warn() {
  echo "$@" 1>&2;
}

mqtt_publish() {
  topic=$1
  payload=$2  
  if [ "$USE_MQTT" = true ];
  then
    mosquitto_pub --host $MQTT_HOST --username "$MQTT_USER" --pw "$MQTT_PASSWORD" --retain -t "$topic" -m "$payload"
  fi
}

mqtt_publish_ha_discovery() {
  station=$1
  phenomenon=$2
  unit_of_measurement=$3
  device_class=$4

  if [ "$MQTT_PUBLISH_HA_DISCOVERY" = false ];
  then
    return
  fi

  global_sensor_prefix=${MQTT_TOPIC_PREFIX%/}
  
  topic="homeassistant/sensor/${global_sensor_prefix}_${station}_${phenomenon}/config"

  if [ ${#device_class} -gt 1 ];
  then 
    device_class_str="\"device_class\": \"${device_class}\","
  else
    device_class_str=""
  fi

  payload=$(cat <<PLEOL
  {
    "device": {
      "name": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
      "identifiers": ["${global_sensor_prefix}_${station}_${phenomenon}"]
    },
    "object_id": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
    "state_topic": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
    "state_class": "measurement",
    "json_attributes_topic": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
    "unit_of_measurement": "${unit}",
    ${device_class_str}
    "value_template": "{{ value_json.${phenomenon} }}"
  }
PLEOL
  )

  if jq -e . >/dev/null 2>&1 <<<"$payload"; 
  then
    mqtt_publish "$topic" "$payload"
  else
    warn "mqtt_publish_ha_discovery: Invalid json for $topic and payload: $payload"
  fi

}

mqtt_publish_state() {
  station=$1
  phenomenon=$2
  value=$3
  timestamp=$4
  latitude=$5
  longitude=$6

  topic="${MQTT_TOPIC_PREFIX}${station}/${phenomenon}"
  payload=$(cat <<PLEOL
  {
    "${phenomenon}": ${value},
    "timestamp": "${timestamp}",
    "latitude": ${latitude},
    "longitude": ${longitude}
  }
PLEOL
  )

  if jq -e . >/dev/null 2>&1 <<<"$payload"; 
  then
    mqtt_publish "$topic" "$payload"
  else
    warn "mqtt_publish_state: Invalid json for $topic and payload: $payload"
  fi
}

normalize_phenomenon() {
  phenomenon=$1
  phenomenon_normalized=`echo ${phenomenon,,} | sed 's/particulate matter < 10 µm/pm10/' | sed 's/particulate matter < 2.5 µm/pm25/' | sed 's/particulate matter < 1 µm/pm1/' | sed 's/ /_/g' | sed 's/(//g' | sed 's/)//g' `  
  if [ "$phenomenon_normalized" = "relative_humidity" ];
  then
    phenomenon_normalized="humidity"
  fi

  echo $phenomenon_normalized
}

phenomenon_to_unit() {
  phenomenon=$1
  unit="µg/m³"

  if [ "$phenomenon" = "temperature" ];
  then
    unit="°C"
  elif [ "$phenomenon" = "humidity" ];
  then
    unit="%"
  elif [ "$phenomenon" = "atmospheric_pressure" ];
  then
    unit="mbar"
  elif [ "$phenomenon" = "carbon_monoxide" ];
  then
    unit="ppm"
  elif [ "$phenomenon" = "carbon_dioxide" ];
  then
    unit="ppm"
  fi

  echo $unit
}

phenomenon_to_device_class() {
  phenomenon=$1
  device_class_list=":date:enum:timestamp:apparent_power:aqi:atmospheric_pressure:battery:carbon_monoxide:carbon_dioxide:current:data_rate:data_size:distance:duration:energy:energy_storage:frequency:gas:humidity:illuminance:irradiance:moisture:monetary:nitrogen_dioxide:nitrogen_monoxide:nitrous_oxide:ozone:ph:pm1:pm10:pm25:power_factor:power:precipitation:precipitation_intensity:pressure:reactive_power:signal_strength:sound_pressure:speed:sulphur_dioxide:temperature:volatile_organic_compounds:volatile_organic_compounds_parts:voltage:volume:volume_storage:water:weight:wind_speed:"
  device_class=""
  
  if [[ ":$device_class_list:" = *:$phenomenon:* ]];    
  then 
    device_class="${phenomenon}"      
  fi


  echo $device_class
}

label_to_location() {
  label=$1
  location=`echo $label | sed 's/ - /|/' | cut -d'|' -f2 | xargs`
  echo $location
}

label_to_location_id() {
  label=$1
  location_id=`echo ${label,,} | sed 's/ - /|/' | cut -d'|' -f1 | xargs`
  echo $location_id
}

location_to_station() {
  location=$1
  station=`echo ${location,,} | sed 's/ /_/g' | sed 's/-/_/g' | sed 's/(//g' | sed 's/)//g' ` 
  echo $station
}


stations_request=`curl \
  -H "Content-Type: application/json" \
  -X GET \
  --silent \
  "$BASE_URL/api/v1/stations?expanded=true"`

by_station=`echo $stations_request | jq -c '.[] | {properties, geometry}' `


IFS=$'\n'
for i in $by_station;
do
  label=`echo $i | jq -r '.properties.label'`
  longitude=`echo $i | jq -r '.geometry.coordinates | .[0]'`
  latitude=`echo $i | jq -r '.geometry.coordinates | .[1]'`

  location=`label_to_location $label`
  location_id=`label_to_location_id $label`
  station=`location_to_station $location`
  timeseries=`echo $i | jq -r '.properties.timeseries | to_entries | map(.key)'`

  if [ -z "$STATIONS_LIST" ] || [[ ",$STATIONS_LIST," = *",$station,"* ]];
  then    
    true
  else
    continue    
  fi

  log "$location $location_id: ($station) $latitude,$longitude"
  timespan="PT0H/$(date -d $TS_DELAY --utc +"%Y-%m-%dT%H:00:00Z")"

  timeseries_values=`curl -H "Content-Type: application/json" -X POST --silent --json "{\"timeseries\":$timeseries, \"timespan\":\"$timespan\"}" "$BASE_URL/api/v1/timeseries/getData"`

  
  for ts in `echo $i | jq -c '.properties.timeseries | to_entries | .[]'`
  do
    ts_id=`echo $ts | jq -r '.key'`    
    phenomenon=`echo $ts | jq -r '.value.phenomenon.label'`
    phenomenon_normalized=$(normalize_phenomenon $phenomenon)
    device_class=$(phenomenon_to_device_class $phenomenon_normalized)
    unit=$(phenomenon_to_unit $phenomenon_normalized)

    ts_value=`echo $timeseries_values | jq -r '.["'$ts_id'"]["values"][0].value'`
    if [ "$ts_value" = "null" ];
    then
      #echo "$ts_id $phenomenon_normalized has no value" > /dev/stderr
      continue
    fi
    ts_timestamp=`echo $timeseries_values | jq -r '.["'$ts_id'"]["values"][0].timestamp'`
    ts_datetime=`date -d @$((ts_timestamp / 1000)) --utc +"%Y-%m-%dT%H:%M:%SZ"`
    
    log "  $ts_id $phenomenon_normalized $ts_value $unit at $ts_datetime"
    mqtt_publish_ha_discovery $station $phenomenon_normalized $unit $device_class
    mqtt_publish_state $station $phenomenon_normalized $ts_value $ts_datetime $latitude $longitude


  done

  
done
