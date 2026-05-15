from typing import List

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

from app import models, schemas
from app.auth import get_current_user
from app.database import get_db

router = APIRouter()

TAG_COLORS = [
    "#3b82f6", "#10b981", "#f59e0b", "#ef4444", "#8b5cf6",
    "#06b6d4", "#f97316", "#ec4899", "#14b8a6", "#6366f1",
    "#84cc16", "#a855f7",
]


def _next_color(db: Session) -> str:
    used = {t.color for t in db.query(models.Tag).all()}
    for c in TAG_COLORS:
        if c not in used:
            return c
    count = db.query(models.Tag).count()
    return TAG_COLORS[count % len(TAG_COLORS)]


def _tag_out(tag: models.Tag, count: int) -> schemas.TagOut:
    return schemas.TagOut(id=tag.id, name=tag.name, color=tag.color, node_count=count)


@router.get("/tags", response_model=List[schemas.TagOut])
def list_tags(db: Session = Depends(get_db), _: models.User = Depends(get_current_user)):
    tags = db.query(models.Tag).order_by(models.Tag.name).all()
    counts = dict(
        db.query(models.NodeTag.tag_id, func.count(models.NodeTag.node_id))
        .group_by(models.NodeTag.tag_id).all()
    )
    return [_tag_out(t, counts.get(t.id, 0)) for t in tags]


@router.post("/tags", response_model=schemas.TagOut, status_code=201)
def create_tag(body: schemas.CreateTagRequest, db: Session = Depends(get_db), _: models.User = Depends(get_current_user)):
    if db.query(models.Tag).filter(models.Tag.name == body.name).first():
        raise HTTPException(status_code=400, detail="Tag đã tồn tại")
    color = body.color if body.color else _next_color(db)
    tag = models.Tag(name=body.name, color=color)
    db.add(tag)
    db.commit()
    db.refresh(tag)
    return _tag_out(tag, 0)


@router.put("/tags/{tag_id}", response_model=schemas.TagOut)
def update_tag(tag_id: int, body: schemas.UpdateTagRequest, db: Session = Depends(get_db), _: models.User = Depends(get_current_user)):
    tag = db.query(models.Tag).filter(models.Tag.id == tag_id).first()
    if not tag:
        raise HTTPException(status_code=404, detail="Tag không tồn tại")
    if body.name is not None:
        conflict = db.query(models.Tag).filter(models.Tag.name == body.name, models.Tag.id != tag_id).first()
        if conflict:
            raise HTTPException(status_code=400, detail="Tên tag đã được dùng")
        tag.name = body.name
    if body.color is not None:
        tag.color = body.color
    db.commit()
    count = db.query(models.NodeTag).filter(models.NodeTag.tag_id == tag_id).count()
    return _tag_out(tag, count)


@router.delete("/tags/{tag_id}")
def delete_tag(tag_id: int, db: Session = Depends(get_db), _: models.User = Depends(get_current_user)):
    tag = db.query(models.Tag).filter(models.Tag.id == tag_id).first()
    if not tag:
        raise HTTPException(status_code=404, detail="Tag không tồn tại")
    db.delete(tag)
    db.commit()
    return {"ok": True}


@router.put("/dashboard/nodes/{node_id}/tags")
def set_node_tags(node_id: str, body: schemas.SetNodeTagsRequest, db: Session = Depends(get_db), _: models.User = Depends(get_current_user)):
    if not db.query(models.Node).filter(models.Node.node_id == node_id).first():
        raise HTTPException(status_code=404, detail="Node không tồn tại")
    db.query(models.NodeTag).filter(models.NodeTag.node_id == node_id).delete()
    for tag_id in body.tag_ids:
        db.add(models.NodeTag(node_id=node_id, tag_id=tag_id))
    db.commit()
    return {"ok": True}


@router.post("/dashboard/nodes/bulk-tags")
def bulk_tag(body: schemas.BulkTagRequest, db: Session = Depends(get_db), _: models.User = Depends(get_current_user)):
    for node_id in body.node_ids:
        for tag_id in body.add_tag_ids:
            exists = db.query(models.NodeTag).filter(
                models.NodeTag.node_id == node_id, models.NodeTag.tag_id == tag_id,
            ).first()
            if not exists:
                db.add(models.NodeTag(node_id=node_id, tag_id=tag_id))
        for tag_id in body.remove_tag_ids:
            db.query(models.NodeTag).filter(
                models.NodeTag.node_id == node_id, models.NodeTag.tag_id == tag_id,
            ).delete()
    db.commit()
    return {"ok": True, "updated": len(body.node_ids)}
