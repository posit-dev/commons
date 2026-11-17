## DataSource.query()


Run one read-only statement, rejecting anything else first.


Usage

``` python
DataSource.query(sql)
```


On a warehouse source the connection identity is checked before the statement is read: access to these tables was decided for one principal, role, and namespace, so a query raises rather than runs once any of those has moved.
