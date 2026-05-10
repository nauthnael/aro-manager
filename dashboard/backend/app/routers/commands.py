from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from app import models, schemas
from app.auth import get_current_user
from app.database import get_db

router = APIRouter()

VALID_ACTIONS = {"restart_aro", "restart_watchdog", "debug_aro", "reboot_vps", "capture_screenshot"}


@router.post("/dashboard/commands", response_model=schemas.CommandOut)
def create_command(
    body: schemas.CreateCommandRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    if body.action not in VALID_ACTIONS:
        raise HTTPException(status_code=400, detail=f"Invalid action. Valid: {sorted(VALID_ACTIONS)}")

    node = db.query(models.Node).filter(models.Node.node_id == body.node_id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")

    # Cancel duplicate pending commands for same action + node
    db.query(models.Command).filter(
        models.Command.node_id == body.node_id,
        models.Command.action == body.action,
        models.Command.status == "pending",
    ).delete()

    cmd = models.Command(
        node_id=body.node_id,
        action=body.action,
        created_by=current_user.username,
    )
    db.add(cmd)
    db.commit()
    db.refresh(cmd)
    return cmd


@router.get("/dashboard/commands", response_model=List[schemas.CommandOut])
def list_commands(
    node_id: Optional[str] = Query(None),
    limit: int = Query(50, le=200),
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    q = db.query(models.Command).order_by(models.Command.created_at.desc())
    if node_id:
        q = q.filter(models.Command.node_id == node_id)
    return q.limit(limit).all()


@router.delete("/dashboard/commands/{cmd_id}")
def cancel_command(
    cmd_id: int,
    db: Session = Depends(get_db),
    _: models.User = Depends(get_current_user),
):
    cmd = db.query(models.Command).filter(models.Command.id == cmd_id).first()
    if not cmd:
        raise HTTPException(status_code=404)
    if cmd.status != "pending":
        raise HTTPException(status_code=400, detail="Only pending commands can be cancelled")
    cmd.status = "failed"
    cmd.result = "Cancelled by user"
    db.commit()
    return {"ok": True}
