"""Async worker skeleton for decoupled user-embedding updates.

Run as separate process reading interaction events from a queue (Kafka/RabbitMQ/SQS).
This keeps feed request latency low and updates user interest vectors out-of-band.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, Sequence

from scripts.feed_recommendation_engine import UserEmbeddingUpdater


@dataclass(frozen=True)
class InteractionEvent:
    user_id: str
    post_embedding: Sequence[float]
    event_type: str  # e.g. click, long_view, share


class QueueConsumer(Protocol):
    def poll(self) -> InteractionEvent | None:
        ...


class FeedEventWorker:
    def __init__(self, consumer: QueueConsumer, embedding_updater: UserEmbeddingUpdater) -> None:
        self.consumer = consumer
        self.embedding_updater = embedding_updater

    def run_once(self) -> bool:
        event = self.consumer.poll()
        if event is None:
            return False

        if event.event_type in {"click", "long_view", "share"}:
            self.embedding_updater.update_from_feedback(
                user_id=event.user_id,
                post_embedding=event.post_embedding,
            )
        return True
