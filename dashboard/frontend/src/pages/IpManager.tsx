import { useState, useEffect, useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { ArrowLeft, RefreshCw, AlertTriangle, Globe, CheckCircle, RotateCcw } from 'lucide-react'
import { NodeIpInfo, IpManagerResponse } from '../types'
import api from '../api/client'
import { useGoBack } from '../utils/navigation'

const col = createColumnHelper<NodeIpInfo>()

type BulkAction = 'update_script' | 'install_scrot' | 'restart_aro' | 'restart_watchdog' | 'reboot_vps' | 'proxy_test'

const BULK_ACTIONS: { id: BulkAction; label: string; cls: string; confirmMsg: (n: number) => string }[] = [
  {
    id: 'update_script',
    label: 'Cập nhật Script',
    cls: 'bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300',
    confirmMsg: n => `Gửi lệnh cập nhật script đến ${n} node?`,
  },
  {
    id: 'restart_aro',
    label: 'Restart ARO',
    cls: 'bg-green-600 hover:bg-green-700 disabled:bg-green-300',
    confirmMsg: n => `Gửi lệnh restart ARO đến ${n} node?`,
  },
  {
    id: 'restart_watchdog',
    label: 'Restart Watchdog',
    cls: 'bg-teal-600 hover:bg-teal-700 disabled:bg-teal-300',
    confirmMsg: n => `Gửi lệnh restart Watchdog đến ${n} node?`,
  },
  {
    id: 'proxy_test',
    label: 'Test Proxy',
    cls: 'bg-cyan-600 hover:bg-cyan-700 disabled:bg-cyan-300',
    confirmMsg: n => `Gửi lệnh test proxy đến ${n} node?`,
  },
  {
    id: 'install_scrot',
    label: 'Cài scrot',
    cls: 'bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300',
    confirmMsg: n => `Gửi lệnh cài scrot đến ${n} node?`,
  },
  {
    id: 'reboot_vps',
    label: 'Reboot VPS',
    cls: 'bg-red-700 hover:bg-red-800 disabled:bg-red-400',
    confirmMsg: n => `Reboot VPS của ${n} node? Hành động này sẽ khởi động lại máy chủ!`,
  },
]

function timeAgo(iso: string | null): string {
  if (!iso) return '—'
  const secs = Math.floor((Date.now() - new Date(iso + 'Z').getTime()) / 1000)
  if (secs < 60) return `${secs}s ago`
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`
  return `${Math.floor(secs / 86400)}d ago`
}

function StatusBadge({ status, isStale }: { status: string | null; isStale: boolean }) {
  if (isStale) return <span className="px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-500">Stale</span>
  const map: Record<string, string> = {
    Online: 'bg-green-100 text-green-700',
    Offline: 'bg-red-100 text-red-700',
    NoInternet: 'bg-yellow-100 text-yellow-700',
    Unbound: 'bg-purple-100 text-purple-700',
    proxy_expired: 'bg-orange-100 text-orange-700',
  }
  const cls = (status && map[status]) || 'bg-gray-100 text-gray-500'
  return <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${cls}`}>{status || '—'}</span>
}

export default function IpManager() {
  useEffect(() => { document.title = '🌐 IP Manager | ARO Dashboard' }, [])
  const navigate = useNavigate()
  const goBack = useGoBack()
  const qc = useQueryClient()
  const [onlyDuplicates, setOnlyDuplicates] = useState(false)
  const [sorting, setSorting] = useState<SortingState>([])
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())

  const { data, isLoading, isFetching, refetch, dataUpdatedAt } = useQuery<IpManagerResponse>({
    queryKey: ['ip-manager', onlyDuplicates],
    queryFn: () => api.get(`/ip-manager/nodes?only_duplicates=${onlyDuplicates}`).then(r => r.data),
    refetchInterval: 30_000,
  })

  const nodes = data?.nodes ?? []
  const selectedCount = selectedIds.size
  const allVisibleIds = nodes.map(n => n.node_id)
  const allSelected = allVisibleIds.length > 0 && allVisibleIds.every(id => selectedIds.has(id))
  const someSelected = allVisibleIds.some(id => selectedIds.has(id))

  const toggleAll = () => {
    if (allSelected) {
      const next = new Set(selectedIds)
      allVisibleIds.forEach(id => next.delete(id))
      setSelectedIds(next)
    } else {
      const next = new Set(selectedIds)
      allVisibleIds.forEach(id => next.add(id))
      setSelectedIds(next)
    }
  }

  const toggleOne = (id: string) => {
    const next = new Set(selectedIds)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    setSelectedIds(next)
  }

  const bulkSend = useMutation({
    mutationFn: ({ action, node_ids }: { action: string; node_ids: string[] }) =>
      api.post('/dashboard/commands/bulk', { action, node_ids }).then(r => r.data),
    onSuccess: (result, vars) => {
      qc.invalidateQueries({ queryKey: ['commands'] })
      alert(`Đã gửi lệnh "${vars.action}" đến ${result.created} node${result.skipped ? ` (bỏ qua ${result.skipped})` : ''}.`)
      setSelectedIds(new Set())
    },
  })

  const bulkRenew = useMutation({
    mutationFn: (node_ids: string[]) =>
      api.post('/renew/bulk', { node_ids }).then(r => r.data),
    onSuccess: (result) => {
      qc.invalidateQueries({ queryKey: ['ip-manager'] })
      alert(`Đã kích hoạt renew cho ${result.triggered} node${result.skipped ? ` (bỏ qua ${result.skipped})` : ''}.`)
      setSelectedIds(new Set())
    },
  })

  const handleBulkAction = (action: BulkAction) => {
    const ids = [...selectedIds]
    const def = BULK_ACTIONS.find(a => a.id === action)!
    if (!confirm(def.confirmMsg(ids.length))) return
    bulkSend.mutate({ action, node_ids: ids })
  }

  const handleBulkRenew = () => {
    const ids = [...selectedIds]
    if (!confirm(`Renew ${ids.length} node đã chọn? Các node đang trong cooldown sẽ bị bỏ qua.`)) return
    bulkRenew.mutate(ids)
  }

  const columns = useMemo(() => [
    col.display({
      id: 'select',
      header: () => (
        <input
          type="checkbox"
          checked={allSelected}
          ref={el => { if (el) el.indeterminate = someSelected && !allSelected }}
          onChange={toggleAll}
          className="rounded border-gray-300 text-blue-600 cursor-pointer"
        />
      ),
      cell: info => (
        <input
          type="checkbox"
          checked={selectedIds.has(info.row.original.node_id)}
          onChange={() => toggleOne(info.row.original.node_id)}
          onClick={e => e.stopPropagation()}
          className="rounded border-gray-300 text-blue-600 cursor-pointer"
        />
      ),
    }),
    col.accessor('node_id', {
      header: 'Node ID',
      cell: info => (
        <button
          className="font-mono text-sm text-blue-600 hover:underline text-left"
          onClick={() => navigate(`/nodes/${encodeURIComponent(info.getValue())}`)}
        >
          {info.getValue()}
        </button>
      ),
    }),
    col.accessor('account', {
      header: 'Account',
      cell: info => <span className="text-sm text-gray-600 truncate max-w-[180px] block">{info.getValue() || '—'}</span>,
    }),
    col.accessor('public_ip', {
      header: 'Exit IP',
      cell: info => {
        const ip = info.getValue()
        const isDup = info.row.original.is_ip_duplicate
        const isUnknown = !ip || ['n/a', 'na', 'unknown', 'none', '0.0.0.0'].includes(ip.trim().toLowerCase())
        if (isUnknown) return <span className="text-gray-300 text-sm">—</span>
        return (
          <span className={`inline-flex items-center gap-1 font-mono text-sm px-2 py-0.5 rounded ${
            isDup ? 'bg-red-100 text-red-700 font-semibold' : 'text-gray-700'
          }`}>
            {isDup && <AlertTriangle size={12} />}
            {ip}
          </span>
        )
      },
    }),
    col.accessor('proxy_host', {
      header: 'Proxy Host',
      cell: info => <span className="text-xs text-gray-500 font-mono">{info.getValue() || '—'}</span>,
    }),
    col.accessor('aro_status', {
      header: 'Trạng thái',
      cell: info => <StatusBadge status={info.getValue()} isStale={info.row.original.is_stale} />,
    }),
    col.accessor('last_seen', {
      header: 'Last Seen',
      cell: info => <span className="text-sm text-gray-500">{timeAgo(info.getValue())}</span>,
    }),
  // eslint-disable-next-line react-hooks/exhaustive-deps
  ], [navigate, selectedIds, allSelected, someSelected])

  const table = useReactTable({
    data: nodes,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  const dupCount = data?.duplicate_ip_count ?? 0
  const affectedCount = data?.affected_node_count ?? 0
  const uniqueCount = (data?.total ?? 0) - affectedCount

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-[1400px] mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <button
              onClick={goBack}
              className="p-1.5 text-gray-500 hover:text-gray-800 hover:bg-gray-100 rounded-lg transition-colors"
            >
              <ArrowLeft size={18} />
            </button>
            <div>
              <h1 className="text-lg font-bold text-gray-800 flex items-center gap-2">
                <Globe size={18} className="text-blue-500" />
                IP Manager
              </h1>
              <p className="text-xs text-gray-400">
                {dataUpdatedAt
                  ? `Cập nhật lúc ${new Date(dataUpdatedAt).toLocaleTimeString('vi-VN')} · tự refresh 30s`
                  : 'Đang tải...'}
              </p>
            </div>
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
      </header>

      <main className="max-w-[1400px] mx-auto px-4 py-5 space-y-4">
        {/* Stats */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div className="bg-white rounded-lg shadow px-4 py-3 border-l-4 border-blue-400">
            <p className="text-xs text-gray-500 uppercase tracking-wide">Tổng nodes</p>
            <p className="text-2xl font-bold text-gray-800">{data?.total ?? '—'}</p>
          </div>
          <div className="bg-white rounded-lg shadow px-4 py-3 border-l-4 border-green-400">
            <p className="text-xs text-gray-500 uppercase tracking-wide">IP độc nhất</p>
            <p className="text-2xl font-bold text-green-700">{isLoading ? '—' : uniqueCount}</p>
          </div>
          <div className={`bg-white rounded-lg shadow px-4 py-3 border-l-4 ${dupCount > 0 ? 'border-red-500' : 'border-gray-200'}`}>
            <p className="text-xs text-gray-500 uppercase tracking-wide">IP trùng</p>
            <p className={`text-2xl font-bold ${dupCount > 0 ? 'text-red-600' : 'text-gray-400'}`}>{isLoading ? '—' : dupCount}</p>
          </div>
          <div className={`bg-white rounded-lg shadow px-4 py-3 border-l-4 ${affectedCount > 0 ? 'border-red-400' : 'border-gray-200'}`}>
            <p className="text-xs text-gray-500 uppercase tracking-wide">Nodes bị ảnh hưởng</p>
            <p className={`text-2xl font-bold ${affectedCount > 0 ? 'text-red-600' : 'text-gray-400'}`}>{isLoading ? '—' : affectedCount}</p>
          </div>
        </div>

        {/* Alert banner */}
        {dupCount > 0 && (
          <div className="bg-red-50 border border-red-200 rounded-lg px-4 py-3 flex items-start gap-3">
            <AlertTriangle size={18} className="text-red-500 mt-0.5 shrink-0" />
            <div>
              <p className="text-sm font-semibold text-red-700">
                Phát hiện {dupCount} Exit IP bị trùng ({affectedCount} nodes)
              </p>
              <p className="text-xs text-red-500 mt-0.5">
                Các nodes dùng chung Exit IP đang được tô đỏ bên dưới. Telegram đã được thông báo — sẽ nhắc lại mỗi 5 phút.
              </p>
            </div>
          </div>
        )}

        {dupCount === 0 && !isLoading && (
          <div className="bg-green-50 border border-green-200 rounded-lg px-4 py-3 flex items-center gap-3">
            <CheckCircle size={18} className="text-green-500 shrink-0" />
            <p className="text-sm text-green-700 font-medium">Tất cả Exit IP là độc nhất — không có trùng lặp.</p>
          </div>
        )}

        {/* Filter + count */}
        <div className="flex items-center gap-4 flex-wrap">
          <label className="flex items-center gap-2 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={onlyDuplicates}
              onChange={e => { setOnlyDuplicates(e.target.checked); setSelectedIds(new Set()) }}
              className="w-4 h-4 accent-red-500"
            />
            <span className="text-sm text-gray-700">Chỉ hiện nodes có IP trùng</span>
          </label>
          <span className="text-sm text-gray-400">{nodes.length} nodes</span>
        </div>

        {/* Bulk action bar */}
        {selectedCount > 0 && (
          <div className="flex items-center gap-3 flex-wrap bg-white border border-blue-200 rounded-xl px-4 py-3 shadow-sm sticky top-14 z-20">
            <span className="text-sm font-medium text-blue-700">{selectedCount} node đã chọn</span>
            <button
              onClick={() => setSelectedIds(new Set())}
              className="text-xs text-gray-400 hover:text-gray-600 underline"
            >
              Bỏ chọn
            </button>
            {selectedCount < nodes.length && (
              <button
                onClick={() => setSelectedIds(new Set(allVisibleIds))}
                className="text-xs text-blue-500 hover:text-blue-700 underline"
              >
                Chọn tất cả {nodes.length} node
              </button>
            )}
            <div className="flex-1" />
            {BULK_ACTIONS.map(action => (
              <button
                key={action.id}
                onClick={() => handleBulkAction(action.id)}
                disabled={bulkSend.isPending}
                className={`px-4 py-2 text-sm font-medium text-white rounded-lg transition-colors disabled:opacity-50 ${action.cls}`}
              >
                {bulkSend.isPending && bulkSend.variables?.action === action.id
                  ? 'Đang gửi...'
                  : `${action.label} (${selectedCount})`}
              </button>
            ))}
            <button
              onClick={handleBulkRenew}
              disabled={bulkRenew.isPending}
              className="flex items-center gap-1.5 px-4 py-2 text-sm font-medium text-white bg-orange-500 hover:bg-orange-600 disabled:bg-orange-300 rounded-lg transition-colors"
            >
              <RotateCcw size={13} />
              {bulkRenew.isPending ? 'Đang renew...' : `Bulk Renew (${selectedCount})`}
            </button>
          </div>
        )}

        {/* Table */}
        <div className="bg-white rounded-lg shadow overflow-hidden">
          {isLoading ? (
            <div className="p-8 text-center text-gray-400 text-sm">Đang tải...</div>
          ) : nodes.length === 0 ? (
            <div className="p-8 text-center text-gray-400 text-sm">Không có dữ liệu.</div>
          ) : (
            <div className="overflow-auto">
              <table className="w-full text-left">
                <thead className="bg-gray-50 border-b border-gray-200 sticky top-0 z-10">
                  {table.getHeaderGroups().map(hg => (
                    <tr key={hg.id}>
                      {hg.headers.map(header => (
                        <th
                          key={header.id}
                          onClick={header.id === 'select' ? undefined : header.column.getToggleSortingHandler()}
                          className={`px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide whitespace-nowrap ${header.id !== 'select' ? 'cursor-pointer select-none hover:text-gray-700' : ''}`}
                        >
                          {flexRender(header.column.columnDef.header, header.getContext())}
                          {header.id !== 'select' && (
                            { asc: ' ↑', desc: ' ↓' }[header.column.getIsSorted() as string] ?? ''
                          )}
                        </th>
                      ))}
                    </tr>
                  ))}
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {table.getRowModel().rows.map(row => {
                    const isDup = row.original.is_ip_duplicate
                    const isSelected = selectedIds.has(row.original.node_id)
                    return (
                      <tr
                        key={row.id}
                        className={
                          isSelected
                            ? 'bg-blue-50'
                            : isDup
                            ? 'bg-red-50 border-l-4 border-l-red-400'
                            : 'hover:bg-gray-50'
                        }
                      >
                        {row.getVisibleCells().map(cell => (
                          <td key={cell.id} className="px-4 py-3 whitespace-nowrap">
                            {flexRender(cell.column.columnDef.cell, cell.getContext())}
                          </td>
                        ))}
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </main>
    </div>
  )
}
