# ias4_global_full.py
import requests
import datetime
import math
import logging
import time
from flask import Flask, render_template_string, jsonify
from flask_socketio import SocketIO
from sgp4.api import Satrec, WGS72
from threading import Thread
import os

# -------------------------------
# CONFIG – Global Ayarlar
# -------------------------------
OPENWEATHER_API_KEY = "YOUR_OPENWEATHER_API_KEY"
SPACE_TRACK_USERNAME = "YOUR_SPACE_TRACK_USERNAME"
SPACE_TRACK_PASSWORD = "YOUR_SPACE_TRACK_PASSWORD"
AIS_HUB_API_KEY = "YOUR_AIS_HUB_API_KEY"

# Hava durumu için gözlem noktaları
WEATHER_LOCATIONS = [
    {"name": "Istanbul", "lat": 41.0082, "lon": 28.9784},
    {"name": "London", "lat": 51.5074, "lon": -0.1278},
    {"name": "Tokyo", "lat": 35.6762, "lon": 139.6503},
    {"name": "Sydney", "lat": -33.8688, "lon": 151.2093},
    {"name": "Cape Town", "lat": -33.9249, "lon": 18.4241},
    {"name": "Dubai", "lat": 25.276987, "lon": 55.296249},
    {"name": "Shanghai", "lat": 31.2304, "lon": 121.4737},
    {"name": "Rio de Janeiro", "lat": -22.9068, "lon": -43.1729}
]

# AIS bounding box (global)
AIS_BOUNDING_BOX = "-180,-90,180,90" # min_lon,min_lat,max_lon,max_lat

ROUTE_HISTORY_LIMIT = 30
SATELLITE_ROUTE_FORECAST_MINUTES = 60

# -------------------------------
# LOGGING
# -------------------------------
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s',
                    handlers=[
                        logging.FileHandler("ias4_global.log"),
                        logging.StreamHandler()
                    ])

def log_event(msg, level=logging.INFO):
    if level == logging.INFO:
        logging.info(msg)
    elif level == logging.ERROR:
        logging.error(msg)
    elif level == logging.WARNING:
        logging.warning(msg)

# -------------------------------
# GLOBAL DATA STORE
# -------------------------------
global_data = {
    "flights": [],
    "ships": [],
    "satellites": [],
    "weather": [],
    "flight_routes": {},
    "ship_routes": {},
    "satellite_routes": {},
    "last_update": None
}

space_track_session = None

# -------------------------------
# DATA COLLECTION HELPERS
# -------------------------------
def login_space_track(username, password):
    global space_track_session
    if not username or username == "YOUR_SPACE_TRACK_USERNAME" or not password:
        log_event("Space-Track.org kullanıcı adı/şifre ayarlanmadı. Login atlanıyor.", level=logging.WARNING)
        return None
    session = requests.Session()
    try:
        response = session.post("https://www.space-track.org/ajaxauth/login", 
                                data={'identity': username, 'password': password}, 
                                timeout=10)
        if response.status_code == 200 and 'Login Successful' in response.text:
            log_event("Space-Track.org login successful.")
            space_track_session = session
            return session
        else:
            log_event(f"Space-Track.org login failed: {response.status_code}", level=logging.ERROR)
            space_track_session = None
            return None
    except requests.exceptions.RequestException as e:
        log_event(f"Space-Track login error: {e}", level=logging.ERROR)
        space_track_session = None
        return None

def process_and_track_entity_routes(entity_list, entity_id_key, route_dict, pos_extract_func, history_limit=ROUTE_HISTORY_LIMIT):
    current_entity_ids = set()
    processed_entities = []

    for entity_raw in entity_list:
        entity_id = entity_raw.get(entity_id_key)
        if not entity_id:
            continue
        current_entity_ids.add(entity_id)
        pos = pos_extract_func(entity_raw)
        if pos is None:
            continue
        processed_entities.append(entity_raw)
        if entity_id not in route_dict:
            route_dict[entity_id] = []
        route_dict[entity_id].append(pos)
        if len(route_dict[entity_id]) > history_limit:
            route_dict[entity_id].pop(0)
    # Eski rotaları sil
    ids_to_remove = [e_id for e_id in route_dict.keys() if e_id not in current_entity_ids]
    for e_id in ids_to_remove:
        if e_id in route_dict:
            del route_dict[e_id]
    return processed_entities

# -------------------------------
# DATA FETCH FUNCTIONS
# -------------------------------
def fetch_weather_data():
    if not OPENWEATHER_API_KEY or OPENWEATHER_API_KEY == "YOUR_OPENWEATHER_API_KEY":
        log_event("OpenWeatherMap API anahtarı yok.", level=logging.WARNING)
        return []
    weather_reports = []
    for loc in WEATHER_LOCATIONS:
        params = {"lat": loc["lat"], "lon": loc["lon"], "appid": OPENWEATHER_API_KEY, "units":"metric"}
        try:
            r = requests.get("http://api.openweathermap.org/data/2.5/weather", params=params, timeout=5)
            if r.status_code == 200:
                data = r.json()
                weather_reports.append({
                    "name": loc["name"],
                    "latitude": loc["lat"],
                    "longitude": loc["lon"],
                    "temperature": data['main']['temp'],
                    "description": data['weather'][0]['description'],
                    "icon": data['weather'][0]['icon']
                })
        except:
            continue
    return weather_reports

def fetch_ais_data():
    if not AIS_HUB_API_KEY or AIS_HUB_API_KEY == "YOUR_AIS_HUB_API_KEY":
        log_event("AIS Hub API anahtarı yok.", level=logging.WARNING)
        return []
    min_lon,min_lat,max_lon,max_lat = map(float, AIS_BOUNDING_BOX.split(','))
    box_param = f"{min_lon},{min_lat},{max_lon},{max_lat}"
    params = {"apikey":AIS_HUB_API_KEY, "box":box_param, "output":"json"}
    try:
        r = requests.get("http://data.aishub.net/ws.php", params=params, timeout=10)
        data = r.json()
        ships_raw = data if isinstance(data,list) else data.get('ships',[])
        processed_ships = []
        for s in ships_raw:
            try:
                lat = float(s.get('LAT',0))
                lon = float(s.get('LON',0))
            except:
                continue
            if lat==0.0 or lon==0.0:
                continue
            processed_ships.append({
                'mmsi':s.get('MMSI'),
                'name':s.get('NAME',f"Ship-{s.get('MMSI')}"),
                'type':s.get('TYPE','Unknown'),
                'longitude':lon,
                'latitude':lat,
                'speed':float(s.get('SOG',0)),
                'course':float(s.get('COG',0))
            })
        return processed_ships
    except:
        return []

def fetch_opensky_data():
    try:
        r = requests.get("https://opensky-network.org/api/states/all", timeout=10)
        if r.status_code == 200:
            states_raw = r.json().get("states",[])
            processed = []
            for f in states_raw:
                if f[5] is None or f[6] is None:
                    continue
                altitude = f[13] if f[13] is not None else (f[7] if f[7] is not None else 10000)
                processed.append({
                    'icao24': f[0],
                    'callsign': f[1].strip() if f[1] else '',
                    'origin_country': f[2],
                    'longitude': f[5],
                    'latitude': f[6],
                    'altitude': altitude,
                    'velocity': f[9],
                    'true_track': f[10]
                })
            return processed
        else:
            return []
    except:
        return []

def fetch_satellite_tle_data():
    global space_track_session
    if not space_track_session:
        login_space_track(SPACE_TRACK_USERNAME, SPACE_TRACK_PASSWORD)
        if not space_track_session:
            return []
    TLE_URL = "https://www.space-track.org/basicspacedata/query/class/tle_latest/ORDINAL/1/EPOCH/%3Enow-30/orderby/NORAD_CAT_ID/limit/100/format/json"
    try:
        r = space_track_session.get(TLE_URL, timeout=10)
        tles = r.json() if r.status_code==200 else []
        processed=[]
        for t in tles:
            if 'NORAD_CAT_ID' in t and 'TLE_LINE1' in t and 'TLE_LINE2' in t:
                t['norad_id']=t['NORAD_CAT_ID']
                t['name']=t.get('OBJECT_NAME', f"SAT-{t['norad_id']}")
                processed.append(t)
        return processed
    except:
        return []

# -------------------------------
# SATELLITE POSITION
# -------------------------------
def get_satellite_position_from_tle(tle1,tle2,time_obj):
    try:
        jd = time_obj.timetuple().tm_yday + (time_obj.hour + time_obj.minute/60 + time_obj.second/3600)/24
        sat = Satrec.twoline2rv(tle1,tle2)
        e,r,v = sat.sgp4(time_obj.year,jd)
        if e==0:
            geodetic = WGS72.eci_to_geodetic(r,time_obj)
            lon = math.degrees(geodetic[0])
            lat = math.degrees(geodetic[1])
            alt_km = geodetic[2]
            return [lon,lat,alt_km*1000]
    except:
        return None

def process_satellites_and_routes(tle_data, route_dict):
    processed=[]
    now = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)
    current_ids=set()
    for t in tle_data:
        norad_id=t['norad_id']
        current_ids.add(norad_id)
        pos = get_satellite_position_from_tle(t['TLE_LINE1'],t['TLE_LINE2'],now)
        if pos:
            processed.append({
                'norad_id':norad_id,
                'name':t['name'],
                'longitude':pos[0],
                'latitude':pos[1],
                'altitude':pos[2]
            })
            # Gelecek rota
            route=[]
            for min_offset in range(0,SATELLITE_ROUTE_FORECAST_MINUTES+1):
                future = now+datetime.timedelta(minutes=min_offset)
                fpos = get_satellite_position_from_tle(t['TLE_LINE1'],t['TLE_LINE2'],future)
                if fpos:
                    route.append(fpos)
            route_dict[norad_id]=route
    # Artık olmayan uydular
    for nid in list(route_dict.keys()):
        if nid not in current_ids:
            del route_dict[nid]
    return processed

# -------------------------------
# LIVE DATA LOOP
# -------------------------------
def live_data_fetch_loop():
    while True:
        try:
            global_data['weather']=fetch_weather_data()
            raw_flights=fetch_opensky_data()
            global_data['flights']=process_and_track_entity_routes(raw_flights,'icao24',global_data['flight_routes'], lambda f:[f['longitude'],f['latitude'],f['altitude']])
            raw_ships=fetch_ais_data()
            global_data['ships']=process_and_track_entity_routes(raw_ships,'mmsi',global_data['ship_routes'], lambda s:[s['longitude'],s['latitude'],0])
            raw_tles=fetch_satellite_tle_data()
            global_data['satellites']=process_satellites_and_routes(raw_tles,global_data['satellite_routes'])
            global_data['last_update']=datetime.datetime.utcnow().isoformat()
        except Exception as e:
            log_event(f"Live fetch loop error: {e}",level=logging.ERROR)
        time.sleep(15)

# -------------------------------
# FLASK + SOCKET.IO
# -------------------------------
app = Flask(__name__)
socketio = SocketIO(app,cors_allowed_origins="*")

INDEX_HTML = """
<!DOCTYPE html>
<html>
<head>
<title>IAS4 Global Command Center</title>
<script src="https://cesium.com/downloads/cesiumjs/releases/1.106/Build/Cesium/Cesium.js"></script>
<style>#cesiumContainer{width:100%;height:90vh;}</style>
</head>
<body>
<h2>IAS4 Global Command Center</h2>
<div id="cesiumContainer"></div>
<script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
<script>
var viewer = new Cesium.Viewer('cesiumContainer',{terrainProvider:Cesium.createWorldTerrain()});
var socket = io();
socket.on('live_data',function(data){console.log(data);});
</script>
</body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(INDEX_HTML)

@app.route("/api/global_data")
def api_global_data():
    return jsonify(global_data)

@socketio.on('connect')
def handle_connect():
    log_event("Client connected")
    socketio.emit('live_data', global_data)

def socketio_loop():
    with app.app_context():
        while True:
            socketio.emit('live_data', global_data)
            time.sleep(10)

# -------------------------------
# MAIN
# -------------------------------
if __name__=="__main__":
    login_space_track(SPACE_TRACK_USERNAME,SPACE_TRACK_PASSWORD)
    Thread(target=live_data_fetch_loop,daemon=True).start()
    Thread(target=socketio_loop,daemon=True).start()
    socketio.run(app,host="0.0.0.0",port=8080,allow_unsafe_werkzeug=True) 