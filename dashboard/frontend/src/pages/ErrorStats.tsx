import { useState, useMemo, useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { useGoBack } from '../utils/navigation'
import {
  ArrowLeft, ArrowUpDown, RefreshCw, ShieldAlert,
  Activity, Server, Wifi,
} from 'lucide-react'
import {
  LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, ReferenceLine,
} from 'recharts'
import api from '../api/client'
import {
  ErrorStatsResponse, NodeErrorStats, ErrorType,
  ERROR_LABELS, ERROR_COLORS,
  RecentEventsResponse, RecentErrorEvent,
  ProxyStatsResponse, ProxyStat,
} from '../types'
import { formatDistanceToNow, parseISO } from 'date-fns'

const ERROR_TYPES: ErrorType[] = ['vps_offline', 'aro_offline', 'no_internet', 'unbound', 'proxy_fail']

// ─── Score helpers ────────────────────────────────────────────────────────────
function scoreColor(score: number) {
  if (score >= 950) return 'text-green-600'
  if (score >= 800) return 'text-amber-500'
  if (score >= 600) return 'text-orange-500'
  return 'text-red-600'
}
function scoreBg(score: number) {
  if (score >= 950) return 'bg-green-50 border-green-200'
  if (score >= 800) return 'bg-amber-50 border-amber-200'
  if (score >= 600) return 'bg-orange-50 border-orange-200'
  return 'bg-red-50 border-red-200'
}
function scoreCardBg(score: number) {
  if (score >= 950) return 'bg-green-50 border-green-300'
  if (score >= 800) return 'bg-amber-50 border-amber-300'
  if (score >= 600) return 'bg-orange-50 border-orange-300'
  return 'bg-red-50 border-red-300'
}

function ScoreBadge({ score }: { score: number }) {
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded-md border text-xs font-bold ${scoreBg(score)} ${scoreColor(score)}`}>
      {score.toFixed(1)}
    </span>
  )
}

// ─── Error type pill ──────────────────────────────────────────────────────────
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

// ─── Sparkline ────────────────────────────────────────────────────────────────
function MiniSparkline({ data }: { data: { date: string; score: number }[] }) {
  if (!data.length) return <span className="text-gray-300 text-xs">—</span>
  return (
    <ResponsiveContainer width={80} height={28}>
      <LineChart data={data.slice(-7)}>
        <Line type="monotone" dataKey="score" stroke="#3b82f6" strokeWidth={1.5} dot={false} />
        <ReferenceLine y={1000} strokeDasharray="3 3" stroke="#e5e7eb" />
      </LineChart>
    </ResponsiveContainer>
  )
}

// ─── Module A: Live Event Feed ────────────────────────────────────────────────
const FEED_FILTERS = ['all', ...ERROR_TYPES, 'ongoing'] as const
type FeedFilter = typeof FEED_FILTERS[number]

const FEED_FILTER_LABELS: Record<FeedFilter, string> = {
  all:            'Tất cả',
  vps_offline:    'VPS Offline',
  aro_offline:    'ARO Offline',
  no_internet:    'No Internet',
  unbound:        'Unbound',
  proxy_fail:     'Proxy Down',
  proxy_expired:  'Proxy Expired',
  ongoing:        'Đang xảy ra',
}

function proxyLabel(e: RecentErrorEvent) {
  if (!e.proxy_host) return null
  if (e.proxy_user) return `${e.proxy_host} (${e.proxy_user})`
  return `${e.proxy_host}:${e.proxy_port ?? ''}`
}

function LiveFeed({ events }: { events: RecentErrorEvent[] }) {
  const [filter, setFilter] = useState<FeedFilter>('all')

  const filtered = useMemo(() => {
    if (filter === 'all') return events
    if (filter === 'ongoing') return events.filter(e => e.ongoing)
    return events.filter(e => e.error_type === filter)
  }, [events, filter])

  return (
    <div className="bg-white rounded-xl shadow-sm flex flex-col" style={{ height: 420 }}>
      <div className="px-4 pt-4 pb-2 border-b border-gray-100">
        <div className="flex items-center gap-2 mb-2">
          <Activity size={15} className="text-red-500" />
          <span className="text-sm font-semibold text-gray-700">Sự kiện gần đây</span>
          <span className="ml-auto text-xs text-gray-400">{events.length} sự kiện</span>
        </div>
        <div className="flex flex-wrap gap-1">
          {FEED_FILTERS.map(f => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              className={`px-2 py-0.5 rounded text-[10px] font-medium transition-colors ${
                filter === f
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
              }`}
            >
              {FEED_FILTER_LABELS[f]}
              {f !== 'all' && f !== 'ongoing' && (
                <span className="ml-1 opacity-70">
                  {events.filter(e => e.error_type === f).length}
                </span>
              )}
            </button>
          ))}
        </div>
      </div>

      <div className="overflow-y-auto flex-1 divide-y divide-gray-50">
        {filtered.length === 0 && (
          <p className="text-center text-gray-400 text-xs py-8">Không có sự kiện</p>
        )}
        {filtered.map(e => {
          const pl = proxyLabel(e)
          const ago = formatDistanceToNow(parseISO(e.started_at), { addSuffix: true })
          return (
            <div key={e.id} className="flex items-start gap-2 px-3 py-2 hover:bg-gray-50">
              <span
                className="mt-0.5 shrink-0 w-2 h-2 rounded-full"
                style={{ backgroundColor: e.ongoing ? ERROR_COLORS[e.error_type] : '#86efac' }}
              />
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-1.5 flex-wrap">
                  <span className="font-mono text-xs font-semibold text-gray-800">{e.node_id}</span>
                  <span
                    className="px-1.5 py-0 rounded text-[10px] font-medium text-white"
                    style={{ backgroundColor: ERROR_COLORS[e.error_type] }}
                  >
                    {ERROR_LABELS[e.error_type]}
                  </span>
                  {e.ongoing
                    ? <span className="text-[10px] text-red-500 font-medium">{e.duration_minutes}m đang xảy ra</span>
                    : <span className="text-[10px] text-green-600 font-medium">✓ {e.duration_minutes}m · đã phục hồi</span>
                  }
                </div>
                <div className="flex items-center gap-2 mt-0.5">
                  {pl && <span className="text-[10px] text-gray-400 font-mono truncate max-w-[200px]">{pl}</span>}
                  <span className="text-[10px] text-gray-400 ml-auto shrink-0">{ago}</span>
                </div>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

// ─── Module D: Proxy Stats (compact preview) ─────────────────────────────────
const MAX_SHOWN_NODES = 2

function ProxyStatsPanel({
  proxies, days, navigate,
}: {
  proxies: ProxyStat[]
  days: number
  navigate: ReturnType<typeof useNavigate>
}) {
  const duplicateCount = proxies.filter(p => p.node_count > 1).length
  const downCount = proxies.filter(p => p.proxy_down_count > 0).length

  // Show top 10 by errors
  const top = useMemo(
    () => [...proxies].sort((a, b) => b.total_errors - a.total_errors).slice(0, 10),
    [proxies]
  )

  return (
    <div className="bg-white rounded-xl shadow-sm flex flex-col" style={{ height: 420 }}>
      <div className="px-4 pt-4 pb-2 border-b border-gray-100 flex items-center gap-2">
        <Wifi size={15} className="text-blue-500" />
        <span className="text-sm font-semibold text-gray-700">Proxy Stats</span>
        <span className="text-xs text-gray-400 ml-1">({days}d · top 10)</span>
        {duplicateCount > 0 && (
          <span className="flex items-center gap-0.5 px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 text-[10px] font-semibold">
            ⚠ {duplicateCount} proxy trùng
          </span>
        )}
        <button
          onClick={() => navigate('/proxy-stats')}
          className="ml-auto text-xs text-blue-600 hover:text-blue-800 font-medium"
        >
          Xem trang đầy đủ →
        </button>
      </div>

      <div className="overflow-y-auto flex-1">
        <table className="w-full text-xs table-fixed">
          <colgroup>
            <col style={{ width: 36 }} />
            <col />
            <col style={{ width: 48 }} />
            <col style={{ width: 52 }} />
          </colgroup>
          <thead className="sticky top-0 bg-gray-50 border-b border-gray-100">
            <tr>
              <th className="px-2 py-2 text-center text-gray-500 font-medium">N</th>
              <th className="text-left px-3 py-2 text-gray-500 font-medium">Proxy / Nodes</th>
              <th className="px-2 py-2 text-right text-gray-500 font-medium">Lỗi</th>
              <th className="px-2 py-2 text-right text-gray-500 font-medium">P.Down</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50">
            {top.map(p => {
              const isDuplicate = p.node_count > 1
              const visibleNodes = p.node_ids.slice(0, MAX_SHOWN_NODES)
              const hiddenCount = p.node_ids.length - visibleNodes.length
              return (
                <tr key={p.proxy_key} className={`hover:bg-gray-50 align-top ${isDuplicate ? 'bg-amber-50' : ''}`}>
                  <td className="px-2 py-2 text-center">
                    <span className={`font-bold text-xs ${isDuplicate ? 'text-amber-600' : 'text-gray-500'}`}>
                      {p.node_count}
                    </span>
                  </td>
                  <td className="px-3 py-2">
                    <span className="font-mono text-[11px] text-gray-700 block leading-tight truncate">
                      {p.proxy_display}
                    </span>
                    <div className="flex flex-wrap gap-1 mt-1">
                      {visibleNodes.map(nid => (
                        <a
                          key={nid}
                          href={`/nodes/${encodeURIComponent(nid)}`}
                          onClick={e => { e.preventDefault(); navigate(`/nodes/${encodeURIComponent(nid)}`) }}
                          className="px-1.5 py-0 rounded bg-blue-50 text-blue-700 hover:bg-blue-100 font-mono text-[10px] leading-5 transition-colors"
                        >
                          {nid}
                        </a>
                      ))}
                      {hiddenCount > 0 && (
                        <span className="text-[10px] text-gray-400 leading-5">+{hiddenCount}</span>
                      )}
                    </div>
                  </td>
                  <td className="px-2 py-2 text-right align-top">
                    <span className={p.total_errors > 0 ? 'font-semibold text-red-600' : 'text-green-500'}>
                      {p.total_errors || '—'}
                    </span>
                  </td>
                  <td className="px-2 py-2 text-right align-top">
                    <span className={p.proxy_down_count > 0 ? 'font-semibold text-red-600' : 'text-gray-400'}>
                      {p.proxy_down_count || '—'}
                    </span>
                  </td>
                </tr>
              )
            })}
            {proxies.length > 10 && (
              <tr>
                <td colSpan={4} className="px-3 py-2 text-center">
                  <button
                    onClick={() => navigate('/proxy-stats')}
                    className="text-xs text-blue-600 hover:text-blue-800"
                  >
                    + {proxies.length - 10} proxies khác — xem trang đầy đủ
                  </button>
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}

// ─── Module B: Node Health Grid ───────────────────────────────────────────────
function NodeGrid({ nodes }: { nodes: NodeErrorStats[] }) {
  const navigate = useNavigate()
  const [showAll, setShowAll] = useState(false)

  const problematic = nodes.filter(n => n.today_score < 950)
  const display = showAll ? nodes : problematic

  return (
    <div className="bg-white rounded-xl shadow-sm p-4">
      <div className="flex items-center gap-2 mb-3">
        <Server size={15} className="text-gray-500" />
        <span className="text-sm font-semibold text-gray-700">Node Health Grid</span>
        <span className="text-xs text-gray-400">
          {problematic.length} node có vấn đề / {nodes.length} tổng
        </span>
        <button
          onClick={() => setShowAll(v => !v)}
          className="ml-auto text-xs text-blue-600 hover:text-blue-800"
        >
          {showAll ? `Ẩn node tốt` : `Hiện tất cả ${nodes.length} nodes`}
        </button>
      </div>

      {display.length === 0 && (
        <p className="text-center text-green-600 text-sm py-6">Tất cả node đang hoạt động tốt 🎉</p>
      )}

      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 xl:grid-cols-8 gap-2">
        {display.map(node => {
          const dominantErr = ERROR_TYPES.find(t => (node.errors_by_type[t] ?? 0) > 0)
          return (
            <a
              key={node.node_id}
              href={`/nodes/${encodeURIComponent(node.node_id)}`}
              onClick={e => { e.preventDefault(); navigate(`/nodes/${encodeURIComponent(node.node_id)}`) }}
              className={`rounded-lg border p-2 text-left hover:shadow-md transition-shadow ${scoreCardBg(node.today_score)}`}
            >
              <p className="font-mono text-[10px] font-semibold text-gray-700 truncate">{node.node_id}</p>
              <p className={`text-sm font-bold mt-0.5 ${scoreColor(node.today_score)}`}>
                {node.today_score.toFixed(0)}
              </p>
              {dominantErr ? (
                <span
                  className="text-[9px] font-medium text-white px-1 py-0 rounded"
                  style={{ backgroundColor: ERROR_COLORS[dominantErr] }}
                >
                  {ERROR_LABELS[dominantErr].split(' ')[0]}
                </span>
              ) : (
                <span className="text-[9px] text-green-600">OK</span>
              )}
            </a>
          )
        })}
      </div>
    </div>
  )
}

// ─── Main: sortable node table (existing) ────────────────────────────────────
type SortKey = 'today_score' | 'avg_7d' | 'avg_30d' | 'total_errors'

function sortNodes(nodes: NodeErrorStats[], key: SortKey, asc: boolean) {
  return [...nodes].sort((a, b) => {
    const va = a[key] ?? -1
    const vb = b[key] ?? -1
    return asc ? va - vb : vb - va
  })
}

// ─── Page ─────────────────────────────────────────────────────────────────────
export default function ErrorStats() {
  useEffect(() => { document.title = '💲 Error Stats | ARO Dashboard' }, [])
  const navigate = useNavigate()
  const goBack = useGoBack()
  const [days, setDays] = useState(30)
  const [sortKey, setSortKey] = useState<SortKey>('today_score')
  const [sortAsc, setSortAsc] = useState(true)

  const { data, isLoading, refetch, isFetching } = useQuery<ErrorStatsResponse>({
    queryKey: ['error-stats', days],
    queryFn: () => api.get(`/errors/stats?days=${days}`).then(r => r.data),
    refetchInterval: 60_000,
  })

  const { data: eventsData, refetch: refetchEvents } = useQuery<RecentEventsResponse>({
    queryKey: ['error-recent-events'],
    queryFn: () => api.get('/errors/recent-events?limit=150').then(r => r.data),
    refetchInterval: 30_000,
  })

  const { data: proxyData } = useQuery<ProxyStatsResponse>({
    queryKey: ['error-proxy-stats'],
    queryFn: () => api.get('/errors/proxy-stats?days=7').then(r => r.data),
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
  const ongoingCount = eventsData?.events.filter(e => e.ongoing).length ?? 0
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

  const handleRefreshAll = () => {
    refetch(); refetchEvents()
  }

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-[1880px] mx-auto px-4 py-3 flex items-center gap-3">
          <button onClick={goBack} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <ShieldAlert size={18} className="text-red-500" />
          <h1 className="text-base font-bold text-gray-800 flex-1">Thống kê lỗi & Chất lượng Node</h1>
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
            onClick={handleRefreshAll}
            disabled={isFetching}
            className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40"
          >
            <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
          </button>
        </div>
      </header>

      <main className="max-w-[1880px] mx-auto px-4 py-5 space-y-5">

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
              <p className="text-xs text-gray-500">Đang có lỗi</p>
              <p className={`text-2xl font-bold mt-1 ${ongoingCount > 0 ? 'text-red-600' : 'text-green-600'}`}>
                {ongoingCount}
              </p>
              <p className="text-xs text-gray-400">sự kiện</p>
            </div>
            <div className="bg-white rounded-xl shadow-sm p-4">
              <p className="text-xs text-gray-500">Node chất lượng kém (&lt;800)</p>
              <p className={`text-2xl font-bold mt-1 ${poorCount > 0 ? 'text-red-600' : 'text-green-600'}`}>
                {poorCount}
              </p>
              {worstNode && poorCount > 0 && (
                <p className="text-xs text-gray-400 truncate">Tệ nhất: {worstNode.node_id}</p>
              )}
            </div>
          </div>
        )}

        {/* Live Feed + Proxy Stats side-by-side */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <LiveFeed events={eventsData?.events ?? []} />

            <ProxyStatsPanel proxies={proxyData?.proxies ?? []} days={7} navigate={navigate} />
        </div>

        {/* Node Health Grid */}
        {data && <NodeGrid nodes={nodes} />}

        {/* Detailed table */}
        <div className="bg-white rounded-xl shadow-sm overflow-hidden">
          <div className="px-4 py-3 border-b border-gray-100 flex items-center gap-2">
            <span className="text-sm font-semibold text-gray-700">Chi tiết theo Node</span>
          </div>
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
                      <SortBtn k="avg_7d" label="TB 7d" />
                    </th>
                    <th className="px-4 py-3 font-medium text-right">
                      <SortBtn k="avg_30d" label="TB 30d" />
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
                      onClick={e => {
                        if (e.ctrlKey || e.metaKey) { window.open(`/nodes/${encodeURIComponent(node.node_id)}`, '_blank'); return }
                        navigate(`/nodes/${encodeURIComponent(node.node_id)}`)
                      }}
                      onAuxClick={e => { if (e.button === 1) window.open(`/nodes/${encodeURIComponent(node.node_id)}`, '_blank') }}
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
                        {node.avg_7d != null
                          ? <span className={scoreColor(node.avg_7d)}>{node.avg_7d.toFixed(1)}</span>
                          : '—'}
                      </td>
                      <td className="px-4 py-3 text-right text-xs text-gray-600">
                        {node.avg_30d != null
                          ? <span className={scoreColor(node.avg_30d)}>{node.avg_30d.toFixed(1)}</span>
                          : '—'}
                      </td>
                      <td className="px-4 py-3 text-xs">
                        {node.total_errors > 0
                          ? <span className="font-medium text-red-600">{node.total_errors}</span>
                          : <span className="text-green-500">0</span>}
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
                      <td colSpan={8} className="py-12 text-center text-gray-400">Chưa có dữ liệu lỗi</td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Legend + score reference */}
        <div className="flex flex-wrap gap-3 text-xs text-gray-500">
          <span className="font-medium">Phân loại điểm:</span>
          <span className="text-green-600 font-medium">≥ 950 Xuất sắc</span>
          <span className="text-amber-500 font-medium">≥ 800 Tốt</span>
          <span className="text-orange-500 font-medium">≥ 600 Trung bình</span>
          <span className="text-red-600 font-medium">&lt; 600 Kém</span>
          <span className="ml-auto">Công thức: 1000 − Σ(phạt theo loại lỗi + thời gian)</span>
        </div>
        <div className="bg-white rounded-xl shadow-sm p-4">
          <p className="text-xs font-semibold text-gray-600 mb-3">Bảng trừ điểm</p>
          <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
            {ERROR_TYPES.map(t => (
              <div key={t} className="rounded-lg border border-gray-100 p-3">
                <div className="text-xs font-bold mb-1" style={{ color: ERROR_COLORS[t] }}>
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
