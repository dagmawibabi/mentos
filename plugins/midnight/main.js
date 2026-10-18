const accents = {
  Violet: { light: '#7C3AED', dark: '#A78BFA' },
  Rose: { light: '#E11D48', dark: '#FB7185' },
  Teal: { light: '#0D9488', dark: '#2DD4BF' },
  Gold: { light: '#B45309', dark: '#FBBF24' },
};

function apply() {
  const name = mentos.storage.get('accent', 'Violet');
  const a = accents[name] || accents.Violet;
  mentos.theme.set({
    textScale: mentos.storage.get('scale', 1),
    light: { accent: a.light, accentInk: '#FFFFFF', bubbleMine: '#1E1B4B', bubbleMineInk: '#EEF2FF' },
    dark: {
      accent: a.dark, accentInk: '#0B0A1A',
      bg: '#0B0A1A', surface: '#13112A', raised: '#1C1938', line: '#2A2650',
      bubbleMine: '#2E2A6B', bubbleMineInk: '#EEF2FF',
    },
  });
}
apply();

mentos.ui.page({
  title: 'Midnight',
  icon: 'moon',
  render: () => [
    { type: 'text', text: 'Accent', style: 'strong' },
    {
      type: 'row',
      children: Object.keys(accents).map(name => ({
        type: 'button',
        label: name,
        style: mentos.storage.get('accent', 'Violet') === name ? 'primary' : 'outline',
        onTap: () => { mentos.storage.set('accent', name); apply(); },
      })),
    },
    { type: 'space', size: 16 },
    {
      type: 'slider',
      label: `Text size ${Math.round(mentos.storage.get('scale', 1) * 100)}%`,
      min: 0.85, max: 1.3,
      value: mentos.storage.get('scale', 1),
      onChange: (v) => { mentos.storage.set('scale', Math.round(v * 100) / 100); apply(); },
    },
    { type: 'text', text: 'Dark mode gets the full indigo surfaces; light mode keeps its surfaces and takes the accent.', style: 'muted' },
  ],
});
