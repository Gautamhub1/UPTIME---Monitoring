# AWS's official base image for Python Lambda functions.
# It already contains the Lambda runtime, boto3, and a local test emulator.
FROM public.ecr.aws/lambda/python:3.12

# Install third-party dependencies first, so Docker can cache this layer
# and skip it when only the app code changes.
COPY app/requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

# Copy the application code (handler.py, checker.py, static/dashboard.html).
COPY app/ ${LAMBDA_TASK_ROOT}/

# "module.function" that Lambda calls for every event.
CMD ["handler.lambda_handler"]
