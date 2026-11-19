import os
import socket

import boto3
import pytest
from moto import mock_aws

# Fake AWS settings so tests never touch a real AWS account.
os.environ.setdefault("AWS_DEFAULT_REGION", "eu-south-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("TABLE_NAME", "uptime-monitor-checks")

PUBLIC_IP = "93.184.216.34"


@pytest.fixture(autouse=True)
def fake_dns(monkeypatch):
    """Every hostname resolves to a public IP unless a test overrides it."""
    import checker

    monkeypatch.setattr(
        checker.socket,
        "getaddrinfo",
        lambda host, port, *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (PUBLIC_IP, 0))],
    )


@pytest.fixture
def aws():
    """A mocked AWS account (moto) with the same DynamoDB table Terraform creates."""
    import handler

    with mock_aws():
        boto3.client("dynamodb").create_table(
            TableName=os.environ["TABLE_NAME"],
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName": "url", "AttributeType": "S"},
                {"AttributeName": "checked_at", "AttributeType": "S"},
            ],
            KeySchema=[
                {"AttributeName": "url", "KeyType": "HASH"},
                {"AttributeName": "checked_at", "KeyType": "RANGE"},
            ],
        )
        handler._clients.clear()  # make the handler create clients inside the mock
        yield
        handler._clients.clear()
