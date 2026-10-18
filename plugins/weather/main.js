// Live weather from open-meteo.com (no key needed), shown as a feed card.
const cities = {
  'Addis Ababa': [9.03, 38.74],
  'Nairobi': [-1.29, 36.82],
  'Lagos': [6.52, 3.38],
  'London': [51.51, -0.13],
  'New York': [40.71, -74.01],
  'Tokyo': [35.68, 139.69],
};
const codes = { 0: 'Clear', 1: 'Mostly clear', 2: 'Partly cloudy', 3: 'Cloudy', 45: 'Fog', 51: 'Drizzle', 61: 'Rain', 63: 'Rain', 65: 'Heavy rain', 71: 'Snow', 80: 'Showers', 95: 'Thunderstorm' };
let now = null;
let error = '';

function city() { return mentos.storage.get('city', 'Addis Ababa'); }

function refresh() {
  const c = cities[city()] || cities['Addis Ababa'];
  mentos.http.request({
    url: `https://api.open-meteo.com/v1/forecast?latitude=${c[0]}&longitude=${c[1]}&current=temperature_2m,wind_speed_10m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1`,
    timeout: 15,
  }, (res) => {
    if (!res.ok || !res.json) { error = res.error || `HTTP ${res.status}`; return; }
    error = '';
    now = {
      temp: Math.round(res.json.current.temperature_2m),
      wind: Math.round(res.json.current.wind_speed_10m),
      sky: codes[res.json.current.weather_code] || 'Weather',
      hi: Math.round(res.json.daily.temperature_2m_max[0]),
      lo: Math.round(res.json.daily.temperature_2m_min[0]),
    };
    mentos.ui.refresh();
  });
}

refresh();
mentos.timer.every(900, refresh);

mentos.ui.slot('feed.top', () => {
  if (error) return { type: 'text', text: `Weather unavailable: ${error}`, style: 'muted' };
  if (!now) return { type: 'text', text: `Loading weather for ${city()}…`, style: 'muted' };
  return { type: 'row', children: [
    { type: 'text', text: `${now.temp}°`, style: 'title' },
    { type: 'text', text: `${now.sky} in ${city()} · H ${now.hi}° L ${now.lo}° · wind ${now.wind} km/h`, style: 'muted' },
  ] };
});

mentos.ui.page({
  title: 'Weather',
  icon: 'sun',
  render: () => [
    now ? { type: 'stat', label: `${now.sky} in ${city()}`, value: `${now.temp}°C` } : { type: 'progress' },
    { type: 'text', text: 'City', style: 'strong' },
    { type: 'row', children: Object.keys(cities).map(name => ({
      type: 'button', label: name, style: name === city() ? 'primary' : 'outline',
      onTap: () => { mentos.storage.set('city', name); now = null; refresh(); },
    })) },
    { type: 'button', label: 'Refresh now', style: 'text', onTap: refresh },
  ],
});
