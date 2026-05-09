import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts'
import { format } from 'date-fns'
import { HistoryPoint } from '../types'

export default function RewardChart({ history }: { history: HistoryPoint[] }) {
  const byDay = new Map<string, number>()
  for (const h of history) {
    const day = format(new Date(h.timestamp + 'Z'), 'MM/dd')
    byDay.set(day, Math.max(byDay.get(day) ?? 0, h.reward_today ?? 0))
  }
  const data = Array.from(byDay.entries()).map(([day, reward]) => ({ day, reward }))

  if (data.length === 0) {
    return <p className="text-gray-400 text-sm text-center py-8">No history data yet</p>
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
