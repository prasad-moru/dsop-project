package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	mongotracing "gopkg.in/DataDog/dd-trace-go.v1/contrib/go.mongodb.org/mongo-driver/mongo"
)

type MongoDBOrderRepo struct {
	db *mongo.Collection
}

func NewMongoDBOrderRepoWithManagedIdentity(
	listConnectionStringsUrl string,
	mongoDb string,
	mongoCollection string,
) (*MongoDBOrderRepo, error) {
	ctx := context.Background()

	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		log.Printf("failed to get default azure credential: %v\n", err)
		return nil, err
	}

	opts := policy.TokenRequestOptions{
		Scopes: []string{"https://management.azure.com/.default"},
	}
	token, err := cred.GetToken(ctx, opts)
	if err != nil {
		log.Printf("failed to get token: %v\n", err)
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", listConnectionStringsUrl, nil)
	if err != nil {
		log.Printf("failed to create request: %v\n", err)
		return nil, err
	}
	req.Header.Add("Authorization", "Bearer "+token.Token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("failed to get connection string: %v\n", err)
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("failed to retrieve connection strings: HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("failed to read response body: %v\n", err)
		return nil, err
	}

	var responseData map[string]interface{}
	if err := json.Unmarshal(body, &responseData); err != nil {
		log.Printf("failed to parse response: %v\n", err)
		return nil, err
	}

	if responseData["connectionStrings"] == nil {
		return nil, fmt.Errorf("connectionStrings not found in response")
	}

	connStrings, ok := responseData["connectionStrings"].([]interface{})
	if !ok || len(connStrings) == 0 {
		return nil, fmt.Errorf("connectionStrings is empty or not an array")
	}

	connStringObj, ok := connStrings[0].(map[string]interface{})
	if !ok || connStringObj["connectionString"] == nil {
		return nil, fmt.Errorf("connectionString not found in first element")
	}

	connectionString, ok := connStringObj["connectionString"].(string)
	if !ok {
		return nil, fmt.Errorf("connectionString is not a string")
	}

	// Use Datadog tracing monitor
	clientOptions := options.Client().
		ApplyURI(connectionString).
		SetMonitor(mongotracing.NewMonitor())

	mongoClient, err := mongo.Connect(ctx, clientOptions)
	if err != nil {
		log.Printf("failed to connect to mongodb: %s", err)
		return nil, err
	}

	err = mongoClient.Ping(ctx, nil)
	if err != nil {
		log.Printf("failed to ping database: %s", err)
		return nil, err
	}
	log.Printf("pong from database")

	collection := mongoClient.Database(mongoDb).Collection(mongoCollection)
	return &MongoDBOrderRepo{collection}, nil
}

func NewMongoDBOrderRepo(
	mongoUri string,
	mongoDb string,
	mongoCollection string,
	mongoUser string,
	mongoPassword string,
) (*MongoDBOrderRepo, error) {
	ctx := context.Background()

	var clientOptions *options.ClientOptions
	if mongoUser == "" && mongoPassword == "" {
		clientOptions = options.Client().
			ApplyURI(mongoUri).
			SetMonitor(mongotracing.NewMonitor())
	} else {
		clientOptions = options.Client().
			ApplyURI(mongoUri).
			SetAuth(options.Credential{
				AuthSource: mongoDb,
				Username:   mongoUser,
				Password:   mongoPassword,
			}).
			SetTLSConfig(&tls.Config{InsecureSkipVerify: false}).
			SetMonitor(mongotracing.NewMonitor())
	}

	mongoClient, err := mongo.Connect(ctx, clientOptions)
	if err != nil {
		log.Printf("failed to connect to mongodb: %s", err)
		return nil, err
	}

	err = mongoClient.Ping(ctx, nil)
	if err != nil {
		log.Printf("failed to ping database: %s", err)
		return nil, err
	}
	log.Printf("pong from database")

	collection := mongoClient.Database(mongoDb).Collection(mongoCollection)
	return &MongoDBOrderRepo{collection}, nil
}

func (r *MongoDBOrderRepo) GetPendingOrders() ([]Order, error) {
	ctx := context.TODO()

	var orders []Order
	cursor, err := r.db.Find(ctx, bson.M{"status": Pending})
	if err != nil {
		log.Printf("Failed to find records: %s", err)
		return nil, err
	}
	defer cursor.Close(ctx)

	if err := cursor.Err(); err != nil {
		log.Printf("Failed to find records: %s", err)
		return nil, err
	}

	for cursor.Next(ctx) {
		var pendingOrder Order
		if err := cursor.Decode(&pendingOrder); err != nil {
			log.Printf("Failed to decode order: %s", err)
			return nil, err
		}
		orders = append(orders, pendingOrder)
	}

	return orders, nil
}

func (r *MongoDBOrderRepo) GetOrder(id string) (Order, error) {
	ctx := context.TODO()

	filter := bson.D{{Key: "orderid", Value: bson.D{{Key: "$eq", Value: id}}}}
	singleResult := r.db.FindOne(ctx, filter)

	var order Order
	err := singleResult.Decode(&order)
	if err != nil {
		log.Printf("Failed to decode order: %s", err)
		return order, err
	}

	return order, nil
}

func (r *MongoDBOrderRepo) InsertOrders(orders []Order) error {
	ctx := context.TODO()

	var ordersInterface []interface{}
	for _, o := range orders {
		ordersInterface = append(ordersInterface, interface{}(o))
	}

	if len(ordersInterface) == 0 {
		log.Printf("No orders to insert into database")
		return nil
	}

	insertResult, err := r.db.InsertMany(ctx, ordersInterface)
	if err != nil {
		log.Printf("Failed to insert order: %s", err)
		return err
	}

	log.Printf("Inserted %v documents into database\n", len(insertResult.InsertedIDs))
	return nil
}

func (r *MongoDBOrderRepo) UpdateOrder(order Order) error {
	ctx := context.TODO()

	filter := bson.D{{Key: "orderid", Value: bson.D{{Key: "$eq", Value: order.OrderID}}}}

	log.Printf("Updating order: %v", order)
	updateResult, err := r.db.UpdateMany(
		ctx,
		filter,
		bson.D{
			{Key: "$set", Value: bson.D{{Key: "status", Value: order.Status}}},
		},
	)
	if err != nil {
		log.Printf("Failed to update order: %s", err)
		return err
	}

	log.Printf("Matched %v documents and updated %v documents.\n",
		updateResult.MatchedCount, updateResult.ModifiedCount)
	return nil
}