import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft, ArrowUpDown, RefreshCw, ShieldAlert } from 'lucide-react'
import {
  LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, ReferenceLine,
} from 'recharts'
import api from '../api/client'
import {
  ErrorStatsResponse, NodeErrorStats, ErrorType,
  ERROR_LABELS, ERROR_COLORS,
} from '../types'

const ERROR_TYPES: ErrorType[] = ['vps_offline', 'aro_offline', 'no_internet', 'unbound', 'proxy_fail']

function scoreColor(score: number): string {
  if (score >= 950) return 'text-green-600'
  if (score >= 800) return 'text-amber-500'
  if (score >= 600) return 'text-orange-500'
  return 'text-red-600'
}

function scoreBg(score: number): string {
  if (score >= 950) return 'bg-green-50 border-green-200'
  if (score >= 800) return 'bg-amber-50 border-amber-200'
  if (score >= 600) return 'bg-orange-50 border-orange-200'
  return 'bg-red-50 border-red-200'
}

function ScoreBadge({ score }: { score: number }) {
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded-md border text-xs font-bold ${scoreBg(score)} ${scoreColor(score)}`}>
      {score.toFixed(1)}
    </span>
  )
}

function MiniSparkline({ data }: { data: { date: string; score: number }[] }) {
  if (!data.length) return <span className="text-gray-300 text-xs">—</span>
  const last7 = data.slice(-7)
  return (
    <ResponsiveContainer width={80} height={28}>
      <LineChart data={last7}>
        <Line
          type="monotone"
          dataKey="score"
          stroke="#3b82f6"
          strokeWidth={1.5}
          dot={false}
        />
        <ReferenceLine y={1000} strokeDasharray="3 3" stroke="#e5e7eb" />
      </LineChart>
    </ResponsiveContainer>
  )
}

function ErrorTypePills({ errors }: { errors: Partial<Record<ErrorType, number>> }) {
  const entries = ERROR_TYPES.filter(t => (errors[t] ?? 0) > 0)
  if (!entries.length) return <span className="text-gray-300 text-xs">—</span>
  return (
    <div className="flex flex-wrap gap-1">
      {entries.map(t => (
        <span
          key={t}
          className="inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded text-[10px] font-medium text-white"
          style={{ backgroundColor: ERROR_COLORS[t] }}
        >
          {ERROR_LABELS[t].split(' ')[0]} ×{errors[t]}
        </span>
      ))}
    </div>
  )
}

type SortKey = 'today_score' | 'avg_7d' | 'avg_30d' | 'total_errors'

function sortNodes(nodes: NodeErrorStats[], key: SortKey, asc: boolean) {
  return [...nodes].sort((a, b) => {
    const va = a[key] ?? -1
    const vb = b[key] ?? -1
    return asc ? va - vb : vb - va
  })
}

export default function ErrorStats() {
  const navigate = useNavigate()
  const [days, setDays] = useState(30)
  const [sortKey, setSortKey] = useState<SortKey>('today_score')
  const [sortAsc, setSortAsc] = useState(true)

  const { data, isLoading, refetch, isFetching } = useQuery<ErrorStatsResponse>({
    queryKey: ['error-stats', days],
    queryFn: () => api.get(`/errors/stats?days=${days}`).then(r => r.data),
    refetchInterval: 60_000,
  })

  const handleSort = (key: SortKey) => {
    if (sortKey === key) setSortAsc(a => !a)
    else { setSortKey(key); setSortAsc(true) }
  }

  const nodes = data ? sortNodes(data.nodes, sortKey, sortAsc) : []
  const totalNodes = nodes.length
  const avgToday = totalNodes
    ? Math.round(nodes.reduce((s, n) => s + n.today_score, 0) / totalNodes * 10) / 10
    : null
  const poorCount = nodes.filter(n => n.today_score < 800).length
  const worstNode = nodes[0]

  function SortBtn({ k, label }: { k: SortKey; label: string }) {
    return (
      <button
        onClick={() => handleSort(k)}
        className="flex items-center gap-1 font-medium text-gray-600 hover:text-gray-900"
      >
        {label}
        <ArrowUpDown size={12} className={sortKey === k ? 'text-blue-500' : 'text-gray-300'} />
      </button>
    )
  }

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-screen-2xl mx-auto px-4 py-3 flex items-center gap-3">
          <button onClick={() => navigate('/')} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <ShieldAlert size={18} className="text-red-500" />
          <div className="flex-1">
            <h1 className="text-base font-bold text-gray-800">Thống kê lỗi & Chất lượng Node</h1>
          </div>
          <select
            value={days}
            onChange={e => setDays(Number(e.target.value))}
            className="text-sm border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            <option value={7}>7 ngày</option>
            <option value={30}>30 ngày</option>
            <option value={60}>60 ngày</option>
            <option value={90}>90 ngày</option>
          </select>
          <button
            onClick={() => refetch()}
            disabled={isFetching}
            className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40"
          >
            <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
          </button>
        </div>
      </header>

      <main className="max-w-screen-2xl mx-auto px-4 py-5 space-y-5">
        {/* Summary cards */}
        {data && (
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
            <div className="bg-white rounded-xl shadow-sm p-4">
              <p className="text-xs text-gray-500">Tổng nodes</p>
              <p className="text-2xl font-bold text-gray-800 mt-1">{totalNodes}</p>
            </div>
            <div className="bg-white rounded-xl shadow-sm p-4">
              <p className="text-xs text-gray-500">Điểm TB hôm nay</p>
              <p className={`text-2xl font-bold mt-1 ${avgToday != null ? scoreColor(avgToday) : 'text-gray-400'}`}>
                {avgToday != null ? avgToday.toFixed(1) : '—'}
              </p>
              <p className="text-xs text-gray-400">/ 1000</p>
            </div>
            <div className="bg-white rounded-xl shadow-sm p-4">
              <p className="text-xs text-gray-500">Node chất lượng kém (&lt;800)</p>
              <p className={`text-2xl font-bold mt-1 ${poorCount > 0 ? 'text-red-600' : 'text-green-600'}`}>
                {poorCount}
              </p>
            </div>
            <div className="bg-white rounded-xl shadow-sm p-4">
              <p className="text-xs text-gray-500">Node điểm thấp nhất</p>
              {worstNode ? (
                <>
                  <p className={`text-lg font-bold mt-1 font-mono truncate ${scoreColor(worstNode.today_score)}`}>
                    {worstNode.today_score.toFixed(1)}
                  </p>
                  <p className="text-xs text-gray-400 truncate">{worstNode.node_id}</p>
                </>
              ) : (
                <p className="text-2xl font-bold mt-1 text-gray-300">—</p>
              )}
            </div>
          </div>
        )}

        {/* Table */}
        <div className="bg-white rounded-xl shadow-sm overflow-hidden">
          {isLoading ? (
            <div className="py-20 text-center text-gray-400">Đang tải...</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-gray-500 border-b border-gray-100 bg-gray-50">
                  <tr>
                    <th className="text-left px-4 py-3 font-medium">Node</th>
                    <th className="text-left px-4 py-3 font-medium">Account</th>
                    <th className="px-4 py-3 font-medium text-right">
                      <SortBtn k="today_score" label="Hôm nay" />
                    </th>
                    <th className="px-4 py-3 font-medium text-right">
                      <SortBtn k="avg_7d" label="TB 7 ngày" />
                    </th>
                    <th className="px-4 py-3 font-medium text-right">
                      <SortBtn k="avg_30d" label="TB 30 ngày" />
                    </th>
                    <th className="px-4 py-3 font-medium text-left">
                      <SortBtn k="total_errors" label={`Lỗi (${days}d)`} />
                    </th>
                    <th className="px-4 py-3 font-medium text-left">Loại lỗi</th>
                    <th className="px-4 py-3 font-medium text-center">Xu hướng 7d</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-50">
                  {nodes.map(node => (
                    <tr
                      key={node.node_id}
                      className="hover:bg-blue-50 cursor-pointer transition-colors"
                      onClick={() => navigate(`/nodes/${encodeURIComponent(node.node_id)}`)}
                    >
                      <td className="px-4 py-3 font-mono text-xs text-gray-700 max-w-[160px]">
                        <span className="truncate block">{node.node_id}</span>
                      </td>
                      <td className="px-4 py-3 text-xs text-gray-500 max-w-[120px]">
                        <span className="truncate block">{node.account ?? '—'}</span>
                      </td>
                      <td className="px-4 py-3 text-right">
                        <ScoreBadge score={node.today_score} />
                      </td>
                      <td className="px-4 py-3 text-right text-xs text-gray-600">
                        {node.avg_7d != null ? (
                          <span className={scoreColor(node.avg_7d)}>{node.avg_7d.toFixed(1)}</span>
                        ) : '—'}
                      </td>
                      <td className="px-4 py-3 text-right text-xs text-gray-600">
                        {node.avg_30d != null ? (
                          <span className={scoreColor(node.avg_30d)}>{node.avg_30d.toFixed(1)}</span>
                        ) : '—'}
                      </td>
                      <td className="px-4 py-3 text-xs">
                        {node.total_errors > 0 ? (
                          <span className="font-medium text-red-600">{node.total_errors}</span>
                        ) : (
                          <span className="text-green-500">0</span>
                        )}
                      </td>
                      <td className="px-4 py-3">
                        <ErrorTypePills errors={node.errors_by_type} />
                      </td>
                      <td className="px-4 py-3" onClick={e => e.stopPropagation()}>
                        <div className="flex justify-center">
                          <MiniSparkline data={node.daily_scores} />
                        </div>
                      </td>
                    </tr>
                  ))}
                  {nodes.length === 0 && !isLoading && (
                    <tr>
                      <td colSpan={8} className="py-12 text-center text-gray-400">
                        Chưa có dữ liệu lỗi
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Legend */}
        <div className="flex flex-wrap gap-3 text-xs text-gray-500">
          <span className="font-medium">Phân loại điểm:</span>
          <span className="text-green-600 font-medium">≥ 950 Xuất sắc</span>
          <span className="text-amber-500 font-medium">≥ 800 Tốt</span>
          <span className="text-orange-500 font-medium">≥ 600 Trung bình</span>
          <span className="text-red-600 font-medium">&lt; 600 Kém</span>
          <span className="ml-auto">Công thức: 1000 − Σ(phạt theo loại lỗi + thời gian)</span>
        </div>

        {/* Score deduction reference */}
        <div className="bg-white rounded-xl shadow-sm p-4">
          <p className="text-xs font-semibold text-gray-600 mb-3">Bảng trừ điểm</p>
          <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
            {ERROR_TYPES.map(t => (
              <div key={t} className="rounded-lg border border-gray-100 p-3">
                <div
                  className="text-xs font-bold mb-1"
                  style={{ color: ERROR_COLORS[t] }}
                >
                  {ERROR_LABELS[t]}
                </div>
                <p className="text-[11px] text-gray-500">
                  {t === 'vps_offline' && '−5 khi xảy ra · −0.65/phút'}
                  {t === 'aro_offline' && '−3 khi xảy ra · −0.50/phút'}
                  {t === 'no_internet' && '−3 khi xảy ra · −0.50/phút'}
                  {t === 'unbound' && '−3 khi xảy ra · −0.40/phút'}
                  {t === 'proxy_fail' && '−2 khi xảy ra · −0.20/phút'}
                </p>
              </div>
            ))}
          </div>
        </div>
      </main>
    </div>
  )
}
