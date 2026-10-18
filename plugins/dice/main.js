// /roll 2d6, /flip, /pick pizza, tacos, sushi
function roll(spec) {
  const m = (spec || '1d6').toLowerCase().split('d');
  const count = Math.min(Math.max(parseInt(m[0]) || 1, 1), 20);
  const sides = Math.min(Math.max(parseInt(m[1]) || 6, 2), 1000);
  const rolls = [];
  for (let i = 0; i < count; i++) rolls.push(1 + Math.floor(Math.random() * sides));
  const total = rolls.reduce((a, b) => a + b, 0);
  return count === 1
    ? `🎲 rolled a d${sides}: ${total}`
    : `🎲 ${count}d${sides}: ${rolls.join(' + ')} = ${total}`;
}

mentos.commands.add('roll', 'Roll dice, like /roll 2d6', (args) => roll(args));
mentos.commands.add('flip', 'Flip a coin', () => Math.random() < 0.5 ? '🪙 Heads' : '🪙 Tails');
mentos.commands.add('pick', 'Pick one: /pick a, b, c', (args) => {
  const options = args.split(',').map(s => s.trim()).filter(s => s.length > 0);
  if (options.length < 2) return '';
  return `🎯 ${options[Math.floor(Math.random() * options.length)]} (from ${options.length})`;
});
