export function diffLines(before, after) {
  const a = before ? before.split('\n') : [], b = after ? after.split('\n') : [];
  const dp = Array.from({ length: a.length + 1 }, () => new Uint16Array(b.length + 1));
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? dp[i+1][j+1]+1 : Math.max(dp[i+1][j], dp[i][j+1]);
  const rows = []; let i = 0, j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) { rows.push({ type: 'same', old: ++i, new: ++j, text: a[i-1] }); }
    else if (i < a.length && (j === b.length || dp[i+1][j] >= dp[i][j+1])) { rows.push({ type: 'del', old: ++i, text: a[i-1] }); }
    else { rows.push({ type: 'add', new: ++j, text: b[j-1] }); }
  }
  return rows;
}

export function diffStats(before, after) { const rows = diffLines(before, after); return { added: rows.filter(r => r.type === 'add').length, removed: rows.filter(r => r.type === 'del').length }; }
