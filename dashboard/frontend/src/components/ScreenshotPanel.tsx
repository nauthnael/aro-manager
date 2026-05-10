import { useEffect, useRef } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { formatDistanceToNow } from 'date-fns'
import { Command } from '../types'
import api from '../api/client'

interface Screenshot {
  data: string
  captured_at: string
}

export default function ScreenshotPanel({ nodeId }: { nodeId: string }) {
  const qc = useQueryClient()
  const lastCompletedId = useRef<number | null>(null)

  const { data: screenshot, isError: noScreenshot } = useQuery<Screenshot>({
    queryKey: ['screenshot', nodeId],
    queryFn: () =>
      api.get(`/dashboard/nodes/${encodeURIComponent(nodeId)}/screenshot`).then(r => r.data),
    retry: false,
    staleTime: 0,
  })

  const { data: commands = [] } = useQuery<Command[]>({
    queryKey: ['commands', nodeId],
    queryFn: () =>
      api.get(`/dashboard/commands?node_id=${encodeURIComponent(nodeId)}&limit=20`).then(r => r.data),
    refetchInterval: 3_000,
  })

  const pendingCmd = commands.find(
    c => c.action === 'capture_screenshot' && (c.status === 'pending' || c.status === 'acked'),
  )

  // Khi có screenshot command vừa completed → refetch ảnh
  useEffect(() => {
    const completed = commands.find(
      c => c.action === 'capture_screenshot' && c.status === 'completed',
    )
    if (completed && completed.id !== lastCompletedId.current) {
      lastCompletedId.current = completed.id
      qc.invalidateQueries({ queryKey: ['screenshot', nodeId] })
    }
  }, [commands, nodeId, qc])

  const capture = useMutation({
    mutationFn: () =>
      api.post('/dashboard/commands', { node_id: nodeId, action: 'capture_screenshot' }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['commands', nodeId] }),
  })

  const handleDownload = () => {
    if (!screenshot) return
    const link = document.createElement('a')
    link.href = `data:image/png;base64,${screenshot.data}`
    link.download = `screenshot_${nodeId}_${Date.now()}.png`
    link.click()
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-2">
        <div className="text-xs text-gray-400">
          {screenshot
            ? `Chụp ${formatDistanceToNow(new Date(screenshot.captured_at + 'Z'), { addSuffix: true })}`
            : noScreenshot
            ? 'Chưa có ảnh'
            : ''}
        </div>
        <div className="flex gap-2">
          {screenshot && (
            <button
              onClick={handleDownload}
              className="px-3 py-1.5 bg-gray-100 hover:bg-gray-200 text-gray-700 text-sm rounded-lg transition-colors"
            >
              Tải xuống
            </button>
          )}
          <button
            onClick={() => capture.mutate()}
            disabled={!!pendingCmd || capture.isPending}
            className="px-3 py-1.5 bg-purple-600 hover:bg-purple-700 text-white text-sm rounded-lg disabled:opacity-50 transition-colors"
          >
            {pendingCmd ? 'Đang chụp...' : 'Chụp màn hình'}
          </button>
        </div>
      </div>

      {screenshot ? (
        <img
          src={`data:image/png;base64,${screenshot.data}`}
          alt="VNC Screenshot"
          className="w-full rounded-lg border border-gray-200 cursor-zoom-in"
          onClick={() => window.open(`data:image/png;base64,${screenshot.data}`, '_blank')}
        />
      ) : (
        <div className="bg-gray-50 border border-dashed border-gray-300 rounded-lg p-10 text-center text-gray-400 text-sm">
          {pendingCmd
            ? 'Đang chờ node chụp màn hình...'
            : 'Nhấn "Chụp màn hình" để xem giao diện VNC của node'}
        </div>
      )}
    </div>
  )
}
