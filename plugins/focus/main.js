// Every switch maps to one layout option and is remembered.
const options = [
  { key: 'hideFeed', label: 'Hide the Feed tab', sub: 'Open straight into Spaces' },
  { key: 'hideWallet', label: 'Hide the Wallet tab' },
  { key: 'hideNetwork', label: 'Hide the Network tab' },
  { key: 'hideStories', label: 'Hide stories' },
  { key: 'hideCompose', label: 'Hide the new post button' },
  { key: 'hideQuick', label: 'Hide quick actions on your profile' },
  { key: 'compact', label: 'Compact spacing' },
  { key: 'iconsOnly', label: 'Icons only in the tab bar' },
  { key: 'original', label: 'Show photos in their own shape', sub: 'Instead of square crops in the feed' },
];

function on(key) { return mentos.storage.get(key, false); }

function apply() {
  const hideTabs = [], hide = [];
  if (on('hideFeed')) hideTabs.push('feed');
  if (on('hideWallet')) hideTabs.push('wallet');
  if (on('hideNetwork')) hideTabs.push('network');
  if (on('hideStories')) hide.push('stories');
  if (on('hideCompose')) hide.push('composeButton');
  if (on('hideQuick')) hide.push('quickActions');
  mentos.layout.set({
    hideTabs: hideTabs,
    hide: hide,
    density: on('compact') ? 'compact' : null,
    navLabels: on('iconsOnly') ? false : null,
    feedImages: on('original') ? 'original' : null,
  });
}
apply();

mentos.ui.page({
  title: 'Focus mode',
  icon: 'star',
  render: () => [
    { type: 'text', text: 'Changes apply instantly and turn off when you disable this plugin.', style: 'muted' },
    ...options.map(o => ({
      type: 'switch', label: o.label, subtitle: o.sub, value: on(o.key),
      onChange: (v) => { mentos.storage.set(o.key, v); apply(); },
    })),
    { type: 'button', label: 'Reset everything', style: 'outline', onTap: () => { options.forEach(o => mentos.storage.set(o.key, false)); apply(); } },
  ],
});
