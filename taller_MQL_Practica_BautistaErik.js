// Taller MQL - MongoDB | Bases de Datos 2 - Universidad El Bosque
// Base de datos: sample_airbnb | Colección: listingsAndReviews

use (sample_airbnb);

// ===================== INSERCIONES =====================

// 1. insertOne básico
use (sample_airbnb);
db.listingsAndReviews.insertOne({
  name: "Cozy Cabin Retreat",
  summary: "Cabaña acogedora rodeada de naturaleza",
  property_type: "Cabin",
  price: NumberDecimal("150.00")
});

use (sample_airbnb);
// 2. insertOne con objeto anidado
db.listingsAndReviews.insertOne({
  name: "Casa Andina Santiago",
  summary: "Casa céntrica en Santiago",
  property_type: "House",
  price: NumberDecimal("120.00"),
  address: { country: "Chile", market: "Santiago" }
});

// 3. insertMany simple
use (sample_airbnb);
db.listingsAndReviews.insertMany([
  { name: "Studio de Arte Urbano", price: NumberDecimal("80.00") },
  { name: "Loft Minimalista", price: NumberDecimal("110.00") }
]);

// 4. insertMany con arrays (amenities)
use (sample_airbnb);
db.listingsAndReviews.insertMany([
  {
    name: "Apartamento Centro Bogotá",
    price: NumberDecimal("95.00"),
    amenities: ["Wifi", "Kitchen", "Free parking"]
  }
]);

// 5. Validación de _id (debe fallar con E11000 duplicate key error)
// El _id "10006546" ya existe en la colección
use (sample_airbnb);
db.listingsAndReviews.insertOne({
  _id: "10006546",
  name: "Listing duplicado",
  price: NumberDecimal("50.00")
});

// ===================== CONSULTAS FIND =====================

// 6. Listings en Brazil
use (sample_airbnb);
db.listingsAndReviews.find(
  { "address.country": "Brazil" },
  { name: 1, price: 1, _id: 0 }
);

// 7. Más de 5 beds
use (sample_airbnb);
db.listingsAndReviews.find(
  { beds: { $gt: 5 } },
  { name: 1, number_of_reviews: 1, _id: 0 }
);

// 8. Precio menor a 75
use (sample_airbnb);
db.listingsAndReviews.find(
  { price: { $lt: NumberDecimal("75.00") } },
  { name: 1, price: 1, property_type: 1, _id: 0 }
);

// 9. $and con objeto anidado
use (sample_airbnb);
db.listingsAndReviews.find({
  $and: [
    { property_type: "Apartment" },
    { "address.market": "New York" }
  ]
});

// 10. $in
use (sample_airbnb);
use (sample_airbnb);db.listingsAndReviews.find({
  property_type: { $in: ["House", "Condominium"] }
});

// 11. Regex sin distinguir mayúsculas/minúsculas
use (sample_airbnb);
db.listingsAndReviews.find(
  { name: { $regex: "luxury", $options: "i" } 
});

// 12. Búsqueda en array: amenity "Heating"
use (sample_airbnb);
db.listingsAndReviews.find(
  { amenities: "Heating" 
});

// 13. Array con exactamente 20 amenities
use (sample_airbnb);
db.listingsAndReviews.find(
  { amenities: { $size: 20 } 
});

// 14. Los 10 más caros
use (sample_airbnb);
db.listingsAndReviews.find(
  {},
  { name: 1, price: 1, "address.country": 1, _id: 0 }
).sort({ price: -1 }).limit(10);

// 15. Sin last_review (ausente o nulo), ordenado por reseñas descendente
use (sample_airbnb);
db.listingsAndReviews.find(
  { last_review: null },
  { name: 1, summary: 1, description: 1, _id: 0 }
).sort({ number_of_reviews: -1 });

// ===================== ACTUALIZACIONES =====================

// 16. updateOne simple
use (sample_airbnb);
db.listingsAndReviews.updateOne(
  { name: "Cozy Cabin Retreat" },
  { $set: { property_type: "Entire home/apt" } }
);

// 17. updateOne con $set y $push (listing del ejercicio 2)
use (sample_airbnb);
db.listingsAndReviews.updateOne(
  { name: "Casa Andina Santiago" },
  {
    $set: { summary: "Casa céntrica en Santiago (actualizada)" },
    $push: { amenities: "Smart TV" }
  }
);

// 18. updateMany con $inc
use (sample_airbnb);
db.listingsAndReviews.updateMany(
  { "address.country": "Spain" },
  { $inc: { number_of_reviews: 1 } }
);

// 19. updateMany con $pull
use (sample_airbnb);
db.listingsAndReviews.updateMany(
  { amenities: "Cable TV" },
  { $pull: { amenities: "Cable TV" } }
);

// 20. updateOne con upsert
use (sample_airbnb);
db.listingsAndReviews.updateOne(
  { name: "Mansión de Prueba" },
  {
    $setOnInsert: {
      name: "Mansión de Prueba",
      price: NumberDecimal("1500.00"),
      address: { country: "United States" }
    }
  },
  { upsert: true }
);

// ===================== AGREGACIONES =====================

// 21. $match y $count (más de 10 amenities)
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $match: { $expr: { $gt: [{ $size: { $ifNull: ["$amenities", []] } }, 10] } } },
  { $count: "listings_con_mas_de_10_amenities" }
]);

// 22. Precio promedio por país
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $group: { _id: "$address.country", precio_promedio: { $avg: "$price" } } },
  { $sort: { precio_promedio: -1 } }
]);

// 23. Top 5 amenities más comunes
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $unwind: "$amenities" },
  { $group: { _id: "$amenities", total: { $sum: 1 } } },
  { $sort: { total: -1 } },
  { $limit: 5 }
]);

// 24. Cantidad de listings por property_type
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $match: { property_type: { $exists: true } } },
  { $group: { _id: "$property_type", cantidad: { $sum: 1 } } },
  { $sort: { cantidad: -1 } }
]);

// 25. $project con conversión de tipo ($toInt)
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $match: { price: { $exists: true } } },
  { $project: { _id: 0, name: 1, price: 1, price_entero: { $toInt: "$price" } } }
]);

// 26. Promedio de review_scores_rating con al menos 10 reseñas
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $match: { number_of_reviews: { $gte: 10 } } },
  { $group: {
      _id: null,
      promedio_rating: { $avg: "$review_scores.review_scores_rating" },
      total_listings: { $sum: 1 }
  } }
]);

// 27. $bucket por rangos de precio: 0-100, 101-300, 301-1000, 1000+
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $match: { price: { $exists: true } } },
  { $addFields: { precio_num: { $toDouble: "$price" } } },
  { $bucket: {
      groupBy: "$precio_num",
      boundaries: [0, 101, 301, 1001],
      default: "1000+",
      output: { cantidad: { $sum: 1 } }
  } }
]);

// 28. $lookup (teórico): unir listings con una colección hosts por host.host_id
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $lookup: {
      from: "hosts",
      localField: "host.host_id",
      foreignField: "host_id",
      as: "info_anfitrion"
  } },
  { $unwind: { path: "$info_anfitrion", preserveNullAndEmptyArrays: true } },
  { $project: { name: 1, "host.host_id": 1, info_anfitrion: 1 } }
]);

// 29. Promedio de accommodates por property_type
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $group: { _id: "$property_type", promedio_huespedes: { $avg: "$accommodates" } } },
  { $sort: { promedio_huespedes: -1 } }
]);

// 30. Listings por año de last_review
use (sample_airbnb);
db.listingsAndReviews.aggregate([
  { $match: { last_review: { $type: "date" } } },
  { $group: { _id: { $year: "$last_review" }, cantidad: { $sum: 1 } } },
  { $sort: { _id: 1 } }
]);