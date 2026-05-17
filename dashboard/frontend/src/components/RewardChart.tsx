import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts'
import { HistoryPoint } from '../types'

function toUtcMidnight(timestamp: string): Date {
  const d = new Date(timestamp + 'Z')
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()))
}

function formatLabel(d: Date): string {
  const m = String(d.getUTCMonth() + 1).padStart(2, '0')
  const day = String(d.getUTCDate()).padStart(2, '0')
  return `${m}/${day}`
}

export default function RewardChart({ history }: { history: HistoryPoint[] }) {
  // Map from UTC-midnight timestamp (ms) → max reward that day
  const byDay = new Map<number, number>()
  let minDate: Date | null = null

  for (const h of history) {
    const d = toUtcMidnight(h.timestamp)
    const key = d.getTime()
    byDay.set(key, Math.max(byDay.get(key) ?? 0, h.reward_today ?? 0))
    if (!minDate || d < minDate) minDate = d
  }

  if (!minDate) {
    return <p className="text-gray-400 text-sm text-center py-8">No history data yet</p>
  }

  // Today in UTC (midnight)
  const now = new Date()
  const todayUtc = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))

  // Build continuous date range from first data point to today
  const data: { day: string; reward: number }[] = []
  const cur = new Date(minDate)
  while (cur <= todayUtc) {
    data.push({ day: formatLabel(cur), reward: byDay.get(cur.getTime()) ?? 0 })
    cur.setUTCDate(cur.getUTCDate() + 1)
  }

  return (
    <ResponsiveContainer width="100%" height={200}>
      <BarChart data={data} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
        <CartesianGrid strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="day" tick={{ fontSize: 11 }} />
        <YAxis tick={{ fontSize: 11 }} />
        <Tooltip formatter={(v: number) => [v.toLocaleString(), 'Reward (pts)']} />
        <Bar dataKey="reward" fill="#3b82f6" radius={[3, 3, 0, 0]} />
      </BarChart>
    </ResponsiveContainer>
  )
}
