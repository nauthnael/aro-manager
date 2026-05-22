import { useState, useMemo } from 'react'
import { X } from 'lucide-react'
import { NodeStatus } from '../types'

interface Props {
  nodes: NodeStatus[]
  onClose: () => void
  onSubmit: (assignments: { node_id: string; proxy: string }[]) => void
  isPending: boolean
}

function isValidProxyFormat(line: string): boolean {
  const parts = line.split(':')
  if (parts.length !== 4) return false
  const port = parseInt(parts[1], 10)
  return !isNaN(port) && String(port) === parts[1].trim() && parts[1].trim() !== ''
}

function proxyKey(line: string): string {
  const parts = line.split(':')
  return parts.length >= 3 ? `${parts[0]}:${parts[1]}:${parts[2]}` : line
}

export default function BulkProxyModal({ nodes, onClose, onSubmit, isPending }: Props) {
  const [text, setText] = useState('')

  const lines = useMemo(
    () => text.split('\n').map(l => l.trim()).filter(l => l.length > 0),
    [text],
  )

  const dupKeys = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const l of lines) {
      const k = proxyKey(l)
      counts[k] = (counts[k] ?? 0) + 1
    }
    return new Set(Object.entries(counts).filter(([, c]) => c > 1).map(([k]) => k))
  }, [lines])

  const validatedLines = useMemo(
    () =>
      lines.map(raw => ({
        raw,
        isDuplicate: dupKeys.has(proxyKey(raw)),
        isInvalidFormat: !isValidProxyFormat(raw),
      })),
    [lines, dupKeys],
  )

  const hasCountError = lines.length < nodes.length
  const hasDuplicates = validatedLines.some(l => l.isDuplicate)
  const hasFormatErrors = validatedLines.some(l => l.isInvalidFormat)
  const canSubmit = !hasCountError && !hasDuplicates && !hasFormatErrors && lines.length > 0

  const handleSubmit = () => {
    if (!canSubmit) return
    onSubmit(nodes.map((node, i) => ({ node_id: node.node_id, proxy: lines[i] })))
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
      <div className="bg-white rounded-xl shadow-xl p-6 w-full max-w-2xl mx-4 flex flex-col gap-4 max-h-[90vh] overflow-y-auto">

        {/* Header */}
        <div className="flex items-center justify-between">
          <h3 className="text-base font-semibold text-gray-800">
            Đổi Proxy cho {nodes.length} node đã chọn
          </h3>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600">
            <X size={18} />
          </button>
        </div>

        {/* Textarea */}
        <div>
          <div className="flex items-center justify-between mb-1">
            <label className="text-sm font-medium text-gray-700">
              Danh sách proxy <span className="text-gray-400 font-normal">(1 dòng / 1 proxy)</span>
            </label>
            <span className={`text-sm font-semibold tabular-nums ${hasCountError ? 'text-red-600' : 'text-green-600'}`}>
              {lines.length}/{nodes.length} proxy
            </span>
          </div>
          <textarea
            value={text}
            onChange={e => setText(e.target.value)}
            placeholder={'host:port:user:pass\nhost:port:user:pass\n...'}
            rows={8}
            spellCheck={false}
            className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-violet-400 resize-y"
          />
          <p className="text-xs text-gray-400 mt-1">
            Định dạng: <code className="bg-gray-100 px-1 rounded">host:port:user:pass</code> · Mỗi dòng tương ứng với 1 node theo thứ tự bên dưới
          </p>
        </div>

        {/* Error messages */}
        {(hasCountError || hasDuplicates || hasFormatErrors) && (
          <div className="flex flex-col gap-0.5">
            {hasCountError && (
              <p className="text-sm text-red-600">
                Cần nhập đủ {nodes.length} proxy (hiện tại chỉ có {lines.length}).
              </p>
            )}
            {hasDuplicates && (
              <p className="text-sm text-red-600">Có proxy bị trùng trong danh sách — xem chi tiết bên dưới.</p>
            )}
            {hasFormatErrors && (
              <p className="text-sm text-red-600">Có proxy sai định dạng — xem chi tiết bên dưới.</p>
            )}
          </div>
        )}

        {/* Mapping preview */}
        {lines.length > 0 && (
          <div className="border border-gray-200 rounded-lg overflow-hidden text-xs">
            <div className="bg-gray-50 px-3 py-2 font-medium text-gray-500 border-b border-gray-200 grid grid-cols-[2rem_1fr_1fr] gap-2">
              <span>#</span>
              <span>Node</span>
              <span>Proxy mới</span>
            </div>
            <div className="divide-y divide-gray-100 max-h-52 overflow-y-auto">
              {nodes.map((node, i) => {
                const vl = validatedLines[i]
                const hasErr = vl && (vl.isDuplicate || vl.isInvalidFormat)
                return (
                  <div
                    key={node.node_id}
                    className={`grid grid-cols-[2rem_1fr_1fr] gap-2 px-3 py-1.5 items-center ${hasErr ? 'bg-red-50' : ''}`}
                  >
                    <span className="text-gray-400 tabular-nums">{i + 1}</span>
                    <span className="text-gray-700 font-mono truncate" title={node.node_id}>
                      {node.node_id}
                    </span>
                    {vl ? (
                      <span
                        className={`font-mono truncate ${hasErr ? 'text-red-600 font-medium' : 'text-green-700'}`}
                        title={vl.raw}
                      >
                        {vl.isDuplicate && '🔴 '}
                        {!vl.isDuplicate && vl.isInvalidFormat && '⚠️ '}
                        {vl.raw}
                      </span>
                    ) : (
                      <span className="text-gray-300 italic">—</span>
                    )}
                  </div>
                )
              })}
            </div>
          </div>
        )}

        {/* Actions */}
        <div className="flex gap-3 justify-end pt-1">
          <button
            onClick={onClose}
            className="px-4 py-2 text-sm text-gray-700 bg-gray-100 rounded-lg hover:bg-gray-200"
          >
            Hủy
          </button>
          <button
            onClick={handleSubmit}
            disabled={!canSubmit || isPending}
            className="px-4 py-2 text-sm text-white bg-violet-600 rounded-lg hover:bg-violet-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isPending ? 'Đang gửi...' : `Xác nhận đổi proxy (${nodes.length} node)`}
          </button>
        </div>

      </div>
    </div>
  )
}
