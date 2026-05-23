import { useState, useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { useGoBack } from '../utils/navigation'
import { ArrowLeft, RefreshCw, TrendingUp } from 'lucide-react'
import {
  LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer,
  CartesianGrid, Legend,
} from 'recharts'
import api from '../api/client'

interface StatsTrendPoint {
  date: string
  no_points_yesterday: number
  no_points_avg: number
  no_points_2days: number
  renew_0points: number
}

interface StatsTrendResponse {
  data: StatsTrendPoint[]
  days: number
}

const METRICS = [
  { key: 'no_points_yesterday' as const, label: 'Không điểm hôm qua', color: '#f97316' },
  { key: 'no_points_avg'       as const, label: 'TB 0 điểm',          color: '#3b82f6' },
  { key: 'no_points_2days'     as const, label: 'Mất điểm 2 ngày',    color: '#ef4444' },
  { key: 'renew_0points'       as const, label: 'Renew 0 điểm',       color: '#7c3aed' },
]

function fmt(dateStr: string) {
  const d = new Date(dateStr)
  return `${String(d.getUTCMonth() + 1).padStart(2, '0')}/${String(d.getUTCDate()).padStart(2, '0')}`
}

function SummaryCard({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div className="bg-white rounded-lg shadow px-4 py-3 border-l-4" style={{ borderColor: color }}>
      <p className="text-[10px] text-gray-500 uppercase tracking-wide leading-tight">{label}</p>
      <p className="text-2xl font-bold mt-1 text-gray-800">{value}</p>
      <p className="text-[10px] text-gray-400 mt-0.5">hôm qua</p>
    </div>
  )
}

export default function StatisticsCharts() {
  useEffect(() => { document.title = '📊 Biểu đồ thống kê' }, [])
  const navigate = useNavigate()
  const goBack = useGoBack()
  const [days, setDays] = useState(30)

  const { data, isLoading, isFetching, refetch } = useQuery<StatsTrendResponse>({
    queryKey: ['stats-trend', days],
    queryFn: () => api.get(`/dashboard/stats-trend?days=${days}`).then(r => r.data),
    staleTime: 5 * 60_000,
  })

  const chartData = (data?.data ?? []).map(p => ({ ...p, date: fmt(p.date) }))
  const latest = data?.data?.[data.data.length - 1]

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <button
              onClick={goBack ?? (() => navigate('/'))}
              className="p-1.5 rounded-lg text-gray-500 hover:text-gray-800 hover:bg-gray-100 transition-colors"
            >
              <ArrowLeft size={18} />
            </button>
            <div className="flex items-center gap-2">
              <TrendingUp size={18} className="text-blue-600" />
              <h1 className="text-base font-bold text-gray-800">Biểu đồ thống kê</h1>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <div className="flex rounded-lg border border-gray-200 overflow-hidden text-sm">
              {[7, 14, 30].map(d => (
                <button
                  key={d}
                  onClick={() => setDays(d)}
                  className={`px-3 py-1.5 transition-colors ${
                    days === d
                      ? 'bg-blue-600 text-white font-medium'
                      : 'text-gray-600 hover:bg-gray-50'
                  }`}
                >
                  {d}d
                </button>
              ))}
            </div>
            <button
              onClick={() => refetch()}
              disabled={isFetching}
              className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40 transition-colors"
              title="Refresh"
            >
              <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-5xl mx-auto px-4 py-5 space-y-5">
        {/* Summary cards — giá trị ngày mới nhất */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          {METRICS.map(m => (
            <SummaryCard
              key={m.key}
              label={m.label}
              value={latest?.[m.key] ?? 0}
              color={m.color}
            />
          ))}
        </div>

        {/* Line chart */}
        <div className="bg-white rounded-lg shadow p-4">
          <h2 className="text-sm font-semibold text-gray-700 mb-4">
            Xu hướng {days} ngày gần nhất
          </h2>
          {isLoading ? (
            <div className="h-[350px] flex items-center justify-center text-gray-400 text-sm">
              Đang tải dữ liệu...
            </div>
          ) : chartData.length === 0 ? (
            <div className="h-[350px] flex items-center justify-center text-gray-400 text-sm">
              Không có dữ liệu
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={350}>
              <LineChart data={chartData} margin={{ top: 5, right: 16, left: 0, bottom: 5 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f0f0f0" />
                <XAxis dataKey="date" tick={{ fontSize: 11 }} />
                <YAxis tick={{ fontSize: 11 }} allowDecimals={false} />
                <Tooltip
                  contentStyle={{ fontSize: 12 }}
                  formatter={(value: number, name: string) => {
                    const m = METRICS.find(x => x.key === name)
                    return [value.toLocaleString(), m?.label ?? name]
                  }}
                />
                <Legend
                  formatter={name => {
                    const m = METRICS.find(x => x.key === name)
                    return <span style={{ fontSize: 12 }}>{m?.label ?? name}</span>
                  }}
                />
                {METRICS.map(m => (
                  <Line
                    key={m.key}
                    type="monotone"
                    dataKey={m.key}
                    stroke={m.color}
                    strokeWidth={2}
                    dot={false}
                    activeDot={{ r: 4 }}
                  />
                ))}
              </LineChart>
            </ResponsiveContainer>
          )}
        </div>

        {/* Ghi chú */}
        <div className="bg-blue-50 border border-blue-100 rounded-lg px-4 py-3 text-xs text-blue-700 space-y-1">
          <p><span className="font-semibold">Không điểm hôm qua:</span> Số node không có reward ngày hôm trước.</p>
          <p><span className="font-semibold">TB 0 điểm:</span> Số node chưa bao giờ có điểm tính đến ngày đó.</p>
          <p><span className="font-semibold">Mất điểm 2 ngày:</span> Node đã từng có điểm nhưng 0 điểm 2 ngày liên tiếp.</p>
          <p><span className="font-semibold">Renew 0 điểm:</span> Node đã renew nhưng chưa kiếm được điểm nào kể từ khi renew.</p>
          <p className="text-blue-500 pt-1">Dữ liệu lấy từ lịch sử NodeHistory, tối đa 30 ngày gần nhất.</p>
        </div>
      </main>
    </div>
  )
}
