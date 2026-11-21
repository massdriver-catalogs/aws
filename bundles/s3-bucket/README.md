# S3 Bucket

A private bucket for one app's files: uploads, exports, reports and other things that don't belong in a database.

## What it needs

An AWS account to deploy into.

## What it makes

- The bucket. Nothing in it is public: public access is blocked, object ACLs are turned off, and requests without TLS are refused. Files are encrypted at rest with an S3-managed key or, if chosen, the bucket's own KMS key.
- Two IAM policies, **read** and **read-write**. An app attaches one to its own role, so access to the bucket is defined in one place. Read covers listing and downloading. Read-write adds uploading and deleting. With a KMS key, both include use of that key.

The bucket's name ends with the AWS account ID, because bucket names are shared by every AWS account in the world.

## Old versions

With **Keep old versions** on, overwriting or deleting a file keeps the previous copy. Old copies are deleted after **Delete old versions after**. Turning versioning off later stops new old-versions being made but keeps the ones that exist until they expire.

## Deleting files on a schedule

**Delete files after** removes every file that many days after it was written. Use it for buckets that only hold temporary data, such as exports or caches. Unfinished multipart uploads are always cleaned up after 7 days.

## Uploads from a browser

To let a website upload straight to the bucket, add its address to **Browser upload origins**. The app's server, holding the read-write policy, creates a presigned URL, and the browser sends the file to that URL. Files never pass through the app's server.

## Decommissioning

The bucket must be empty before it can be deleted. Decommissioning fails while files or old versions remain.
