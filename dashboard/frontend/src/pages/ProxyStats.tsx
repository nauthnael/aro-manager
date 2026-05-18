import { useState, useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft, ArrowUpDown, RefreshCw, Wifi, AlertTriangle } from 'lucide-react'
import api from '../api/client'
import { ProxyStatsResponse, ProxyStat, ErrorType, ERROR_LABELS, ERROR_COLORS } from '../types'

const ERROR_TYPES: ErrorType[] = ['vps_offline', 'aro_offline', 'no_internet', 'unbound', 'proxy_fail']

type SortKey = 'total_errors' | 'node_count' | 'proxy_down_count' | 'total_score'

function sortProxies(list: ProxyStat[], key: SortKey, asc: boolean) {
  return [...list].sort((a, b) => {
    const va = a[key] ?? 0
    const vb = b[key] ?? 0
    return asc ? va - vb : vb - va
  })
}

function ErrorPills({ errors }: { errors: Partial<Record<ErrorType, number>> }) {
  const entries = ERROR_TYPES.filter(t => (errors[t] ?? 0) > 0)
  if (!entries.length) return <span className="text-gray-300 text-xs">—</span>
  return (
    <div className="flex flex-wrap gap-1">
      {entries.map(t => (
        <span
          key={t}
          className="px-1.5 py-0.5 rounded text-[10px] font-medium text-white"
          style={{ backgroundColor: ERROR_COLORS[t] }}
        >
          {ERROR_LABELS[t].split(' ')[0]} ×{errors[t]}
        </span>
      ))}
    </div>
  )
}

export default function ProxyStats() {
  const navigate = useNavigate()
  const [days, setDays] = useState(7)
  const [sortKey, setSortKey] = useState<SortKey>('total_errors')
  const [sortAsc, setSortAsc] = useState(false)
  const [filter, setFilter] = useState<'all' | 'duplicate' | 'down'>('all')

  const { data, isLoading, refetch, isFetching } = useQuery<ProxyStatsResponse>({
    queryKey: ['proxy-stats', days],
    queryFn: () => api.get(`/errors/proxy-stats?days=${days}`).then(r => r.data),
    refetchInterval: 60_000,
  })

  const proxies = data?.proxies ?? []

  const filtered = useMemo(() => {
    let list = proxies
    if (filter === 'duplicate') list = list.filter(p => p.node_count > 1)
    if (filter === 'down') list = list.filter(p => p.proxy_down_count > 0)
    return sortProxies(list, sortKey, sortAsc)
  }, [proxies, filter, sortKey, sortAsc])

  const duplicateCount = proxies.filter(p => p.node_count > 1).length
  const downCount = proxies.filter(p => p.proxy_down_count > 0).length
  const totalNodes = proxies.reduce((s, p) => s + p.node_count, 0)

  const handleSort = (key: SortKey) => {
    if (sortKey === key) setSortAsc(a => !a)
    else { setSortKey(key); setSortAsc(false) }
  }

  function SortBtn({ k, label }: { k: SortKey; label: string }) {
    return (
      <button
        onClick={() => handleSort(k)}
        className="inline-flex items-center gap-1 font-medium text-gray-600 hover:text-gray-900 whitespace-nowrap"
      >
        {label}
        <ArrowUpDown size={11} className={sortKey === k ? 'text-blue-500' : 'text-gray-300'} />
      </button>
    )
  }

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-[1880px] mx-auto px-4 py-3 flex items-center gap-3">
          <button onClick={() => navigate('/errors')} className="p-1 text-gray-500 hover:text-gray-800">
            <ArrowLeft size={18} />
          </button>
          <Wifi size={18} className="text-blue-500" />
          <h1 className="text-base font-bold text-gray-800 flex-1">Proxy Stats</h1>
          <select
            value={days}
            onChange={e => setDays(Number(e.target.value))}
            className="text-sm border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            <option value={7}>7 ngày</option>
            <option value={14}>14 ngày</option>
            <option value={30}>30 ngày</option>
            <option value={60}>60 ngày</option>
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

      <main className="max-w-[1880px] mx-auto px-4 py-5 space-y-4">

        {/* Summary cards */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <div className="bg-white rounded-xl shadow-sm p-4">
            <p className="text-xs text-gray-500">Tổng proxies</p>
            <p className="text-2xl font-bold text-gray-800 mt-1">{proxies.length}</p>
          </div>
          <div className="bg-white rounded-xl shadow-sm p-4">
            <p className="text-xs text-gray-500">Tổng nodes</p>
            <p className="text-2xl font-bold text-gray-800 mt-1">{totalNodes}</p>
          </div>
          <div
            className={`rounded-xl shadow-sm p-4 cursor-pointer transition-colors ${
              duplicateCount > 0
                ? 'bg-amber-50 border border-amber-300 hover:bg-amber-100'
                : 'bg-white'
            }`}
            onClick={() => setFilter(f => f === 'duplicate' ? 'all' : 'duplicate')}
          >
            <p className="text-xs text-gray-500 flex items-center gap-1">
              {duplicateCount > 0 && <AlertTriangle size={11} className="text-amber-500" />}
              Proxy dùng &gt;1 node
            </p>
            <p className={`text-2xl font-bold mt-1 ${duplicateCount > 0 ? 'text-amber-600' : 'text-green-600'}`}>
              {duplicateCount}
            </p>
            {duplicateCount > 0 && (
              <p className="text-[10px] text-amber-500 mt-0.5">
                {filter === 'duplicate' ? 'Đang lọc — click để bỏ' : 'Click để lọc'}
              </p>
            )}
          </div>
          <div
            className={`rounded-xl shadow-sm p-4 cursor-pointer transition-colors ${
              downCount > 0
                ? 'bg-red-50 border border-red-300 hover:bg-red-100'
                : 'bg-white'
            }`}
            onClick={() => setFilter(f => f === 'down' ? 'all' : 'down')}
          >
            <p className="text-xs text-gray-500">Proxy Down ({days}d)</p>
            <p className={`text-2xl font-bold mt-1 ${downCount > 0 ? 'text-red-600' : 'text-green-600'}`}>
              {downCount}
            </p>
            {downCount > 0 && (
              <p className="text-[10px] text-red-400 mt-0.5">
                {filter === 'down' ? 'Đang lọc — click để bỏ' : 'Click để lọc'}
              </p>
            )}
          </div>
        </div>

        {/* Table */}
        <div className="bg-white rounded-xl shadow-sm overflow-hidden">
          {/* Filter bar */}
          <div className="px-4 py-2.5 border-b border-gray-100 flex items-center gap-2 text-xs text-gray-500">
            <span>Hiển thị:</span>
            {(['all', 'duplicate', 'down'] as const).map(f => (
              <button
                key={f}
                onClick={() => setFilter(f)}
                className={`px-2 py-0.5 rounded font-medium transition-colors ${
                  filter === f ? 'bg-blue-600 text-white' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
                }`}
              >
                {f === 'all' && `Tất cả (${proxies.length})`}
                {f === 'duplicate' && `Proxy trùng (${duplicateCount})`}
                {f === 'down' && `Proxy Down (${downCount})`}
              </button>
            ))}
            <span className="ml-auto text-gray-400">{filtered.length} kết quả</span>
          </div>

          {isLoading ? (
            <div className="py-20 text-center text-gray-400">Đang tải...</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs text-gray-500 bg-gray-50 border-b border-gray-100">
                  <tr>
                    <th className="text-left px-4 py-3 font-medium">
                      <SortBtn k="node_count" label="Nodes" />
                    </th>
                    <th className="text-left px-4 py-3 font-medium">Proxy</th>
                    <th className="text-left px-4 py-3 font-medium">Hostnames</th>
                    <th className="text-right px-4 py-3 font-medium">
                      <SortBtn k="total_score" label={`Tổng điểm (${days}d)`} />
                    </th>
                    <th className="text-right px-4 py-3 font-medium">
                      <SortBtn k="total_errors" label="Lỗi" />
                    </th>
                    <th className="text-right px-4 py-3 font-medium">
                      <SortBtn k="proxy_down_count" label="Proxy Down" />
                    </th>
                    <th className="text-left px-4 py-3 font-medium">Loại lỗi</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-50">
                  {filtered.map(p => {
                    const isDuplicate = p.node_count > 1
                    return (
                      <tr
                        key={p.proxy_key}
                        className={`hover:bg-blue-50 transition-colors ${isDuplicate ? 'bg-amber-50' : ''}`}
                      >
                        {/* Nodes count */}
                        <td className="px-4 py-3">
                          <span className={`inline-flex items-center gap-1 font-semibold ${
                            isDuplicate ? 'text-amber-600' : 'text-gray-700'
                          }`}>
                            {isDuplicate && <AlertTriangle size={12} className="text-amber-500" />}
                            {p.node_count}
                          </span>
                        </td>

                        {/* Proxy */}
                        <td className="px-4 py-3 font-mono text-xs text-gray-700 max-w-[220px]">
                          <span className="block truncate">{p.proxy_display}</span>
                        </td>

                        {/* Hostnames */}
                        <td className="px-4 py-3">
                          <div className="flex flex-wrap gap-1">
                            {p.node_ids.map(nid => (
                              <button
                                key={nid}
                                onClick={() => navigate(`/nodes/${encodeURIComponent(nid)}`)}
                                className="px-1.5 py-0.5 rounded bg-blue-50 text-blue-700 hover:bg-blue-100 font-mono text-[11px] transition-colors"
                              >
                                {nid}
                              </button>
                            ))}
                          </div>
                        </td>

                        {/* Total score */}
                        <td className="px-4 py-3 text-right">
                          <span className={`font-semibold text-sm ${
                            p.total_score > 0 ? 'text-gray-800' : 'text-gray-400'
                          }`}>
                            {p.total_score > 0 ? p.total_score.toLocaleString('vi-VN', { maximumFractionDigits: 0 }) : '—'}
                          </span>
                        </td>

                        {/* Total errors */}
                        <td className="px-4 py-3 text-right">
                          <span className={p.total_errors > 0 ? 'font-semibold text-red-600' : 'text-green-500'}>
                            {p.total_errors || '—'}
                          </span>
                        </td>

                        {/* Proxy down */}
                        <td className="px-4 py-3 text-right">
                          <span className={p.proxy_down_count > 0 ? 'font-semibold text-red-600' : 'text-gray-400'}>
                            {p.proxy_down_count || '—'}
                          </span>
                        </td>

                        {/* Error types */}
                        <td className="px-4 py-3">
                          <ErrorPills errors={p.errors_by_type} />
                        </td>
                      </tr>
                    )
                  })}
                  {filtered.length === 0 && !isLoading && (
                    <tr>
                      <td colSpan={7} className="py-12 text-center text-gray-400">
                        Không có dữ liệu
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Legend */}
        <div className="flex items-center gap-4 text-xs text-gray-500 flex-wrap">
          <span className="flex items-center gap-1">
            <AlertTriangle size={12} className="text-amber-500" />
            Hàng vàng = proxy bị dùng cho nhiều hơn 1 node (vi phạm nguyên tắc 1 proxy–1 node)
          </span>
          <span className="ml-auto">
            Tổng điểm = cộng điểm tất cả các ngày trong kỳ của node đang dùng proxy đó
          </span>
        </div>
      </main>
    </div>
  )
}
